// DynamicDispatcher.swift
// マシンをまたぐ run(`run` の DeviceMachineRunner / `api run` の ApiRunMachineFanout)で、子の
// `--work-queue` の要求(WorkQueueProtocol)を1か所で受け、DynamicSplit の規則で1本ずつ答える親の配り手(RR-8.1)。
//
// - 状態は全部 LockedValue の中。要求は子ごとの読み取りスレッド・タイマー・終了通知から並行に来る
// - 返事は臨界区間の外で送る(送り先の書き込みが詰まっても他の判断を止めない)
// - 子の stdin が `ssh -tt` の先では EOF が当てにならないので、**要求には必ず答える**(もう無ければ none)
// - 対象外(DR-214): 子が「機械の中に回し直す先が無い」対象外のシナリオを `na` で返してきたら、`NotApplicableHandoff.decide` で
//   他のエントリの未試行の台へ回す(pending へ戻し、試したエントリを除外)/ 対象外で確定 / 実行しなかった赤で確定を答える
// - 子が落ちても、渡したシナリオは回し直さない(途中まで走ったかもしれない)。まだ誰にも渡していない分だけ残りへ配る

import FTCore
import Foundation

final class DynamicDispatcher: Sendable {

    typealias Cancel = @Sendable () -> Void
    /// afterMs 後に fire を1回呼ぶ。戻り値で取り消す(取り消し後に呼ばれても害は無い = 再判定が1回増えるだけ)
    typealias Timer = @Sendable (_ afterMs: Double, _ fire: @escaping @Sendable () -> Void) -> Cancel

    private struct Held {
        let lane: DynamicSplit.Lane
        let req: Int
    }

    private struct Busy {
        let scenario: DynamicSplit.Scenario
        let since: Double
    }

    /// 単位(ID × バリアント)ごとの対象外の記帳(DR-214)。`tried` = 試して対象外と宣言したエントリ(回し直しの除外)・
    /// `departedInChild` = 子の中で試していない台が落ちている(その子の申告)
    private struct NotApplicableRecord {
        /// 単位の platform。種類の覆いはこの platform の観測だけで見る(iOS の種類で Android の台を覆わない)
        let platform: String
        var tried: Set<Int> = []
        var departedInChild = false
    }

    private struct State {
        var pending: [DynamicSplit.Scenario]
        var notApplicable: [ScenarioUnitKey: NotApplicableRecord] = [:]
        /// 要求を出したことのあるレーンだけ(供給中のレーンを空きと数えない)。値 nil = 空いて返事待ち
        var lanes: [DynamicSplit.Lane: Busy?] = [:]
        var held: [Held] = []
        var assigned: [Int: [ScenarioUnitKey]] = [:]
        /// エントリ → 配った単位のうち、子が機械の中で回し直している最中と知らせてきたもの(`kept`。DR-214 ②)。
        /// レーンの印(`lanes`)はそのレーンの次の要求で消えるので、回し直し中の単位はこちらでしか見えない
        var kept: [Int: Set<ScenarioUnitKey>] = [:]
        var exited: Set<Int> = []
        /// platform → エントリ番号 → 観測した種類(`entryKinds` の答え。不明のエントリは載せない)。その platform の対象外が初めて来るまで空
        var entryKinds: [String: [Int: Set<String>]] = [:]
        var interrupted = false
        var cancelTimer: Cancel?
        /// 束ねた先(RR-8.3)。渡した直後に record する
        var bindings = DynamicSplit.Bindings()
        /// 臨界区間の中で積み、外(`withState`)で出す束ねたときの1行
        var logs: [String] = []
    }

    private let state: LockedValue<State>
    /// 単位 → 配るシナリオ(対象外の問い合わせで pending へ戻す元。子の中で別のレーンへ回った分は、親が割り当てたレーンの印と一致しない)
    private let scenariosByUnit: [ScenarioUnitKey: DynamicSplit.Scenario]
    private let estimateMs: @Sendable (DynamicSplit.Scenario, Int) -> Double
    private let nowMs: @Sendable () -> Double
    private let timer: Timer
    private let send: @Sendable (Int, WorkQueueProtocol.Reply) -> Void
    /// false = `--no-lpt`(候補を ID 順に試す)。子のカタログの並びは配る順に効かないので、ここで決める
    private let lpt: Bool
    /// エントリ番号 → そのグループの platforms(RR-8.3: 全メンバーの OS を持たないエントリへ未束縛の singleMachine のクラスを渡さない)
    private let entryPlatforms: [Int: Set<String>]
    /// エントリ番号 → 束ねたときのログに出す名前(マシン名)
    private let entryLabel: @Sendable (Int) -> String
    private let log: @Sendable (String) -> Void
    /// platform → エントリ番号 → 観測した種類(iOS だけ引く)。**I/O なので臨界区間の外で呼ぶ**。答えは platform ごとに1回だけ使う
    private let entryKindsResolver: @Sendable (_ platform: String) -> [Int: Set<String>]
    /// `entryKindsResolver` を引いた platform。引く間は他の対象外の問い合わせも待つ(2回引かない)
    private let kindsResolved = LockedValue<Set<String>>([])
    private let kindsResolveGate = NSLock()

    /// - scenarios: 走らせるシナリオ。platform は解決済み(`resolve`)
    /// - estimateMs: (シナリオ, エントリ番号) → 見込み[ms]。エントリ番号は DynamicSplit.Lane.entry と同じ
    /// - send: 保留していた要求への返事の送り先(エントリ番号, 返事)。`handle` の戻り値はこれを通らない
    init(scenarios: [DynamicSplit.Scenario],
         estimateMs: @escaping @Sendable (DynamicSplit.Scenario, Int) -> Double,
         nowMs: @escaping @Sendable () -> Double = DynamicDispatcher.monotonicClock(),
         timer: @escaping Timer = DynamicDispatcher.dispatchTimer,
         lpt: Bool,
         entryPlatforms: [Int: Set<String>] = [:],
         entryLabel: @escaping @Sendable (Int) -> String = { "entry \($0)" },
         log: @escaping @Sendable (String) -> Void = { _ in },
         entryKinds: @escaping @Sendable (_ platform: String) -> [Int: Set<String>],
         send: @escaping @Sendable (Int, WorkQueueProtocol.Reply) -> Void) {
        self.lpt = lpt
        self.entryPlatforms = entryPlatforms
        self.entryLabel = entryLabel
        self.log = log
        self.entryKindsResolver = entryKinds
        state = LockedValue(State(pending: scenarios))
        scenariosByUnit = Dictionary(scenarios.map { ($0.unitKey, $0) }, uniquingKeysWith: { first, _ in first })
        self.estimateMs = estimateMs
        self.nowMs = nowMs
        self.timer = timer
        self.send = send
    }

    // MARK: - 入口

    /// 子(エントリ番号)からの要求。すぐ答えられるなら返事を返す。保留なら nil(あとで `send` から届く)
    func handle(_ want: WorkQueueProtocol.Want, fromEntry entry: Int) -> WorkQueueProtocol.Reply? {
        let lane = DynamicSplit.Lane(entry: entry, lane: want.lane, platform: want.platform)
        let answers: [(Held, WorkQueueProtocol.Reply)] = withState { s in
            let held = Held(lane: lane, req: want.req)
            if s.exited.contains(entry) { return [] }
            if s.interrupted { return [(held, .init(req: want.req, none: true))] }
            s.lanes[lane] = .some(nil)
            s.held.append(held)
            return drainLocked(&s)
        }
        var mine: WorkQueueProtocol.Reply?
        for (held, reply) in answers {
            if mine == nil, held.lane == lane, held.req == want.req {
                mine = reply
            } else {
                send(held.lane.entry, reply)
            }
        }
        return mine
    }

    /// 子からの対象外の問い合わせ(DR-214)。**必ず即答する**(`want` と違い保留しない)。
    /// 回し直す(`.handOn`)ときは pending へ戻し、その子の割り当てから外す(子は結果を捨てる = 結果の照合に残さない)
    func handleNotApplicable(_ na: WorkQueueProtocol.NotApplicable, fromEntry entry: Int) -> WorkQueueProtocol.Reply {
        var verdict: NotApplicableHandoff.Verdict = .skipped
        // 割り当てていない単位の問い合わせ(下で無視する)のために、全マシンへの観測を撃たない
        if state.withLock({ $0.assigned[entry]?.contains(na.unit) == true }) { resolveKindsIfNeeded(platform: na.platform) }
        let answers: [(Held, WorkQueueProtocol.Reply)] = withState { s in
            // 親が割り当てたシナリオだけ(子は機械の中で別のレーンへ回すので、宣言したレーンは親の割り当てのレーンと限らない)
            let unit = na.unit
            guard s.assigned[entry]?.contains(unit) == true, let scenario = scenariosByUnit[unit],
                  scenario.group == nil else { return [] }
            // 子の中の回し直しは尽きた(親へ聞いてきた)。保留している他のエントリの要求は、どの判定でも見直す
            s.kept[entry]?.remove(unit)
            var record = s.notApplicable[unit] ?? NotApplicableRecord(platform: na.platform)
            record.tried.insert(entry)
            record.departedInChild = record.departedInChild || na.dep
            s.notApplicable[unit] = record
            let known = Set(entryPlatforms.filter { $0.value.contains(na.platform) }.keys)
                .union(s.lanes.keys.filter { $0.platform == na.platform }.map(\.entry))
                .union(record.tried)
            let left = known.intersection(s.exited)
            verdict = NotApplicableHandoff.decide(
                tried: Set(record.tried.map(String.init)),
                live: Set(known.subtracting(left).map(String.init)),
                departed: Set(left.map(String.init)).union(record.departedInChild ? ["child-local"] : []),
                kinds: Self.kinds(of: record.platform, s))
            guard verdict == .handOn else { return drainLocked(&s) }
            s.pending.append(scenario)
            if let index = s.assigned[entry]?.lastIndex(of: unit) { s.assigned[entry]?.remove(at: index) }
            // 親がそのシナリオを走らせていると記録しているレーンは空く(次の要求で再び数える)
            for (key, busy) in s.lanes where key.entry == entry && busy?.scenario.unitKey == unit { s.lanes[key] = .some(nil) }
            return drainLocked(&s)
        }
        for (held, reply) in answers { send(held.lane.entry, reply) }
        return .init(req: na.req, verdict: verdict)
    }

    /// 種類の観測は iOS だけ(Android のプロファイルは機種を持たない = 台ごと。DR-214)。platform ごとに1回
    private func resolveKindsIfNeeded(platform: String) {
        guard platform == "ios" else { return }
        kindsResolveGate.lock()
        defer { kindsResolveGate.unlock() }
        guard kindsResolved.withLock({ $0.insert(platform).inserted }) else { return }
        let kinds = entryKindsResolver(platform)
        state.withLock { $0.entryKinds[platform] = kinds }
        // 観測できなかったエントリは台ごとの回し直しに戻る(誤りではないが遅い)。黙らずに1行言う
        let unknown = entryPlatforms.filter { $0.value.contains(platform) && kinds[$0.key] == nil }.keys.sorted()
        if !unknown.isEmpty {
            log("→ could not observe the \(platform) device kinds on \(unknown.map(entryLabel).joined(separator: ", "));"
                + " not-applicable scenarios are handed to every device there")
        }
    }

    /// 鍵(エントリ番号の文字列)→ その platform で観測した種類。`NotApplicableHandoff` へ渡す形
    private static func kinds(of platform: String, _ s: State) -> [String: Set<String>] {
        Dictionary(uniqueKeysWithValues: (s.entryKinds[platform] ?? [:]).map { (String($0.key), $0.value) })
    }

    /// そのエントリが単位を受け取れないか = 試した、または試したエントリと同じ観測の種類(DR-214)。
    /// **配る側(`reachable`・`triedBy`・`mayReceiveHandBack`)は全部ここを通す** —— 判定が割れると、覆ったエントリへ単位を渡して
    /// 子を起こすだけの空振りになる
    private static func isExcluded(entry: Int, unit: ScenarioUnitKey, _ s: State) -> Bool {
        guard let record = s.notApplicable[unit] else { return false }
        return record.tried.contains(entry)
            || NotApplicableHandoff.covered(String(entry), tried: Set(record.tried.map(String.init)),
                                            kinds: kinds(of: record.platform, s))
    }

    /// 子が、配った単位を機械の中で回し直し始めた / 終えた(`kept`。返事なし)。割り当てていない単位は無視する(偽の知らせで待たせない)
    func handleKept(_ kept: WorkQueueProtocol.Kept, fromEntry entry: Int) {
        let answers: [(Held, WorkQueueProtocol.Reply)] = withState { s in
            guard !s.exited.contains(entry) else { return [] }
            if kept.on {
                guard s.assigned[entry]?.contains(kept.unit) == true else { return [] }
                s.kept[entry, default: []].insert(kept.unit)
                // そのマシンで保留している要求は起こして手元を見直させる(保留中のレーンは手元に戻った item を取れない。
                // 互いの回し直しを待ち合う2台のマシンは、これが無いと終わらない)
                let mine = s.held.filter { $0.lane.entry == entry }
                s.held.removeAll { $0.lane.entry == entry }
                return mine.map { ($0, WorkQueueProtocol.Reply(req: $0.req, again: true)) }
            }
            guard s.kept[entry]?.remove(kept.unit) != nil else { return [] }
            return drainLocked(&s)
        }
        for (held, reply) in answers { send(held.lane.entry, reply) }
    }

    /// 子が終わった。そのレーンと保留中の要求を捨てる。渡し済みのシナリオは回し直さない
    func childExited(entry: Int) {
        let answers: [(Held, WorkQueueProtocol.Reply)] = withState { s in
            s.exited.insert(entry)
            s.kept[entry] = nil
            s.lanes = s.lanes.filter { $0.key.entry != entry }
            s.held.removeAll { $0.lane.entry == entry }
            return drainLocked(&s)
        }
        for (held, reply) in answers { send(held.lane.entry, reply) }
    }

    /// 中断(SIGINT/SIGTERM)。保留中も以後の要求も全部 none で答える。
    /// 子も中断で自分の待ちを解く(`ScenarioPullSource.stopWaiting`)が、中断が子へ届かない経路もあるので親からも止める
    func interrupt() {
        let answers: [(Held, WorkQueueProtocol.Reply)] = withState { s in
            s.interrupted = true
            return drainLocked(&s)
        }
        for (held, reply) in answers { send(held.lane.entry, reply) }
    }

    /// 臨界区間で body を実行し、区間の中で積んだ束ねたときのログを区間の外で出す(返事を送る前)
    private func withState(_ body: (inout State) -> [(Held, WorkQueueProtocol.Reply)])
        -> [(Held, WorkQueueProtocol.Reply)] {
        let (answers, logs) = state.withLock { s -> ([(Held, WorkQueueProtocol.Reply)], [String]) in
            let answers = body(&s)
            let logs = s.logs
            s.logs.removeAll()
            return (answers, logs)
        }
        for line in logs { log(line) }
        return answers
    }

    // MARK: - 読み出し

    func assignedUnits(entry: Int) -> [ScenarioUnitKey] { state.withLock { $0.assigned[entry] ?? [] } }
    var assignedCounts: [Int: Int] { state.withLock { $0.assigned.mapValues(\.count) } }
    /// 誰にも渡さなかったシナリオ(全部の子が終わった後に読む)
    var unhandedUnits: [ScenarioUnitKey] { state.withLock { $0.pending.map(\.unitKey) } }
    var isInterrupted: Bool { state.withLock { $0.interrupted } }
    /// まだ誰にも渡していないシナリオ(複数対象の配り手 MultiTargetRunner が仕事の残りの見込みに使う。読むだけ)
    var pendingScenarios: [DynamicSplit.Scenario] { state.withLock { $0.pending } }

    /// 束ねた先のエントリが終わった(子が落ちた)ため、他へ移さずに残るシナリオ(RR-8.3。decide がもう他へ渡さない)
    var keptUnhanded: [(unit: ScenarioUnitKey, placement: ClassPlacement)] {
        state.withLock { s in
            s.pending.compactMap { scenario -> (unit: ScenarioUnitKey, placement: ClassPlacement)? in
                guard let group = Self.keptGroup(scenario, s) else { return nil }
                return (unit: scenario.unitKey, placement: group.placement)
            }
        }
    }

    /// まだ配れる残り(`pendingScenarios` から、終わったエントリに束ねたクラスの分を除く。仕事の終わりの判定と見込み用)
    var handablePendingScenarios: [DynamicSplit.Scenario] {
        state.withLock { s in s.pending.filter { Self.keptGroup($0, s) == nil } }
    }

    private static func keptGroup(_ scenario: DynamicSplit.Scenario, _ s: State) -> DynamicSplit.Group? {
        guard let group = scenario.group else { return nil }
        let entry: Int?
        switch group.placement {
        case .singleMachine: entry = s.bindings.machine[group.name]
        case .singleDevice, .inOrder: entry = s.bindings.device[group.name]?.entry
        }
        guard let entry, s.exited.contains(entry) else { return nil }
        return group
    }

    /// 束ねたクラスの残りを他へ移さなかった旨の1行(英語)。`neverHandedLine` の後に出す
    static func keptUnhandedLine(_ kept: [(unit: ScenarioUnitKey, placement: ClassPlacement)]) -> String? {
        guard !kept.isEmpty else { return nil }
        let attributes = Set(kept.map { $0.placement.attributeName }).sorted().joined(separator: ", ")
        let maxListed = 5
        let listed = kept.prefix(maxListed).map { $0.unit.description }.joined(separator: ", ")
        let suffix = kept.count > maxListed ? ", …" : ""
        return "ℹ️ \(kept.count) of them were not moved to another \(kept.contains { $0.placement.bindsDevice } ? "device or machine" : "machine")"
            + " because their class is kept on the one that ended (\(attributes)): \(listed)\(suffix)"
    }

    // MARK: - 判定

    private func timerFired() {
        let answers: [(Held, WorkQueueProtocol.Reply)] = withState { drainLocked(&$0) }
        for (held, reply) in answers { send(held.lane.entry, reply) }
    }

    /// 保留中の要求を古い順に判定し直す。1本でも渡したら状態が変わるので最初から回し直す。
    /// 最後に、次に判断が変わりうる時刻でタイマーを張り直す(固定周期では回さない)
    private func drainLocked(_ s: inout State) -> [(Held, WorkQueueProtocol.Reply)] {
        let now = nowMs()
        var answers: [(Held, WorkQueueProtocol.Reply)] = []
        var earliest: Double?

        if s.interrupted {
            for held in s.held { answers.append((held, .init(req: held.req, none: true))) }
            s.held.removeAll()
            s.lanes.removeAll()
        }

        // 対象外の記帳は見直しの中で変わらない(1回の drain で1回だけ作る)
        let triedBy = s.notApplicable.reduce(into: [ScenarioUnitKey: Set<Int>]()) { result, element in
            let entries = Set((s.entryKinds[element.value.platform] ?? [:]).keys)
            result[element.key] = element.value.tried.union(entries.filter { Self.isExcluded(entry: $0, unit: element.key, s) })
        }
        var progressed = true
        while progressed {
            progressed = false
            earliest = nil
            for (position, held) in s.held.enumerated() {
                var laneStates: [DynamicSplit.LaneState] = []
                for (lane, busy) in s.lanes {
                    let info: (scenario: DynamicSplit.Scenario, since: Double)? =
                        busy.map { (scenario: $0.scenario, since: $0.since) }
                    laneStates.append(DynamicSplit.LaneState(lane: lane, busy: info))
                }
                // 対象外で戻された(試したエントリが除外の)シナリオは、そのエントリへ渡さない
                let reachable = s.pending.filter { !Self.isExcluded(entry: held.lane.entry, unit: $0.unitKey, s) }
                var decision = DynamicSplit.decide(
                    for: held.lane, now: now, pending: reachable, lanes: laneStates, estimateMs: estimateMs, lpt: lpt,
                    bindings: s.bindings, entryPlatforms: entryPlatforms,
                    triedBy: triedBy)
                // 尽きたレーンは、他のエントリが走らせているシナリオが対象外で自分(未試行)へ戻ってくるかもしれない間は終わらせない
                if case .none = decision, Self.mayReceiveHandBack(held.lane, s, scenariosByUnit: scenariosByUnit) {
                    decision = .hold(reconsiderAt: nil)
                }
                switch decision {
                case .assign(let unit):
                    guard let index = s.pending.firstIndex(where: { $0.unitKey == unit }) else { continue }
                    let scenario = s.pending.remove(at: index)
                    if let group = scenario.group {
                        let wasBound = group.placement == .singleMachine
                            ? s.bindings.machine[group.name] != nil : s.bindings.device[group.name] != nil
                        s.bindings.record(scenario, to: held.lane)
                        if !wasBound { s.logs.append(keptLine(group, lane: held.lane)) }
                    }
                    s.lanes[held.lane] = .some(Busy(scenario: scenario, since: now))
                    s.assigned[held.lane.entry, default: []].append(unit)
                    s.held.remove(at: position)
                    answers.append((held, .init(req: held.req, unit: unit)))
                    progressed = true
                case .none:
                    s.lanes.removeValue(forKey: held.lane)
                    s.held.remove(at: position)
                    answers.append((held, .init(req: held.req, none: true)))
                    progressed = true
                case .hold(let reconsiderAt):
                    if let reconsiderAt, reconsiderAt < (earliest ?? .infinity) { earliest = reconsiderAt }
                }
                if progressed { break }
            }
        }

        s.cancelTimer?()
        s.cancelTimer = nil
        if let earliest, !s.held.isEmpty {
            s.cancelTimer = timer(max(earliest - now, 0)) { [weak self] in self?.timerFired() }
        }
        return answers
    }

    /// 他のレーンが束ねていないシナリオを走らせている(レーンの印)か、他のエントリが機械の中で回し直している(`kept`)最中で、
    /// それを自分のエントリがまだ試していない(= 対象外で戻ってくる)か。
    /// **レーンの印は同じエントリの別のレーンも数える** —— 1回の見直しで同じ子の1本へ単位を渡し、残りへ none を返すと、子は
    /// 渡した単位をまだ走らせていると記帳する前に none を処理してレーンを終わらせうる(子の `othersMayHandBack` が空振り)。
    /// 終わったレーンは子の中で「試していない台が落ちた」になり、全台が試した後に赤になった(11/23 の確認の手元の4台)
    private static func mayReceiveHandBack(_ requester: DynamicSplit.Lane, _ s: State,
                                           scenariosByUnit: [ScenarioUnitKey: DynamicSplit.Scenario]) -> Bool {
        func untried(_ unit: ScenarioUnitKey) -> Bool {
            !isExcluded(entry: requester.entry, unit: unit, s)
        }
        let running = s.lanes.contains { lane, busy in
            guard lane.platform == requester.platform, lane != requester,
                  !s.exited.contains(lane.entry), let busy, busy.scenario.group == nil else { return false }
            return untried(busy.scenario.unitKey)
        }
        if running { return true }
        return s.kept.contains { entry, units in
            guard entry != requester.entry, !s.exited.contains(entry) else { return false }
            return units.contains { unit in
                guard let scenario = scenariosByUnit[unit], scenario.platform == requester.platform,
                      scenario.group == nil else { return false }
                return untried(unit)
            }
        }
    }

    /// 束ねた瞬間の1行(英語)。マシンに寄せるならマシン名、デバイスに寄せるならマシン名 / レーン
    private func keptLine(_ group: DynamicSplit.Group, lane: DynamicSplit.Lane) -> String {
        let place = group.placement.bindsDevice ? "\(entryLabel(lane.entry)) / \(lane.lane)" : entryLabel(lane.entry)
        return "\(group.name): kept on \(place) (\(group.placement.attributeName))"
    }

    // MARK: - 既定の時計・タイマー

    /// 単調な[ms]。0 の位置は呼んだ時点(DynamicSplit は差と大小しか使わない)
    static func monotonicClock() -> @Sendable () -> Double {
        let origin = ContinuousClock.now
        return {
            DurationConversion.seconds(ContinuousClock.now - origin) * 1000
        }
    }

    static let dispatchTimer: Timer = { afterMs, fire in
        let cancelled = LockedValue(false)
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .milliseconds(Int(max(afterMs, 0).rounded(.up)))
        ) {
            if !cancelled.withLock({ $0 }) { fire() }
        }
        return { cancelled.withLock { $0 = true } }
    }

    // MARK: - platform の解決

    /// platform を宣言していないシナリオの platform。**子の `ResolvedProfile.undeclaredScenarioPlatform`
    /// (iOS のデバイスがあれば ios)と同じ規則**を、親が持つ全グループのデバイスへ掛ける。
    /// 子は自分の担当デバイスだけで解決するが、undeclared を渡すレーンはこの値の platform のレーンだけなので、
    /// その子は必ず同じ platform のデバイスを持ち(ios なら iOS を持つ子 = ios・android なら全員 android)結果が一致する
    static func undeclaredPlatform(groups: [DeviceMachineRunner.Group]) -> String {
        groups.contains(where: { $0.platforms.contains("ios") }) ? "ios" : "android"
    }

    static func resolve(_ scenarios: [(id: String, variant: String?, platform: String?)],
                        defaultPlatform: String) -> [DynamicSplit.Scenario] {
        scenarios.map { DynamicSplit.Scenario(id: $0.id, variant: $0.variant, platform: $0.platform ?? defaultPlatform) }
    }

    /// 寄せる属性のクラスのシナリオには group を載せる(RR-8.3)。属性が無ければ上と同じ
    /// ScenarioInfo は ID だけなので variant は呼び手が決める(バリアントの無い経路は nil)
    /// バリアントは `plan` が展開する(シナリオの順 × 宣言の順。`variantRank` = 宣言の番号)
    static func resolve(_ scenarios: [ScenarioInfo], plan: RunVariantPlan, defaultPlatform: String) -> [DynamicSplit.Scenario] {
        let byID = Dictionary(scenarios.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return plan.units(of: scenarios).compactMap { unit in
            byID[unit.id].map {
                DynamicSplit.Scenario(id: $0.id, variant: unit.variant, platform: $0.platform ?? defaultPlatform,
                                      group: group(of: $0), variantRank: plan.rank(of: unit.variant))
            }
        }
    }

    static func group(of info: ScenarioInfo) -> DynamicSplit.Group? {
        guard let placement = info.placement else { return nil }
        return DynamicSplit.Group(name: ClassPlacementRules.className(of: info.id), placement: placement,
                                  order: info.order)
    }

    /// 静的な割り当て(FleetSplit.plan の groups:)用。キー = 単位(ID × バリアント)
    static func groups(of infos: [ScenarioInfo], plan: RunVariantPlan) -> [ScenarioUnitKey: DynamicSplit.Group] {
        var result: [ScenarioUnitKey: DynamicSplit.Group] = [:]
        for info in infos {
            guard let g = group(of: info) else { continue }
            for unit in plan.units(of: [info]) { result[unit] = g }
        }
        return result
    }

    static func groups(of infos: [ScenarioInfo], variant: String?) -> [ScenarioUnitKey: DynamicSplit.Group] {
        var result: [ScenarioUnitKey: DynamicSplit.Group] = [:]
        for info in infos { if let g = group(of: info) { result[info.unitKey(variant: variant)] = g } }
        return result
    }

    /// 親が持つ全グループのエントリ番号 → platforms(DynamicDispatcher の entryPlatforms)
    static func entryPlatforms(groups: [DeviceMachineRunner.Group]) -> [Int: Set<String>] {
        Dictionary(uniqueKeysWithValues: groups.enumerated().map { ($0.offset, $0.element.platforms) })
    }

    /// 複数マシンに分かれる run の開始時の検査(RR-8.3)。違反なら断る文言
    static func coverageError(selected: [ScenarioInfo], groups: [DeviceMachineRunner.Group]) -> String? {
        ClassPlacementRules.singleMachineCoverageError(
            selected, defaultPlatform: undeclaredPlatform(groups: groups),
            entries: groups.map { (label: $0.machineLabel, platforms: $0.platforms) })
    }

    /// そのグループの子へ `--scenario` として渡す全候補(子がビルド・一覧に使う)。実際に回すのは配られた分だけ
    static func candidateUnits(for group: DeviceMachineRunner.Group,
                               in scenarios: [DynamicSplit.Scenario]) -> [ScenarioUnitKey] {
        scenarios.filter { group.platforms.contains($0.platform) }.map(\.unitKey)
    }
}

/// 子プロセスの stdin への書き込み口。**書き手ごとに独立した直列のキュー**で非同期に書く(呼んだスレッドをブロックしない =
/// 子の stdout を読むスレッドが、詰まった子の stdin で止まらない。1台の詰まりが他の子への行を止めない)。
/// 同じ子への行(割り振りの返事・run メモ・開始の行)は全部ここを通すので、積んだ順に届く。
/// `attach` の前に来た行は捨てずに溜め、attach で順に流す。子が死んでいても落とさない(EPIPE は黙って捨てる)
final class ChildStdinWriter: @unchecked Sendable {
    // @unchecked の根拠: handle / backlog / closed は queue の上でしか触らない
    private let queue = DispatchQueue(label: "fleetest.child-stdin-writer")
    private var handle: FileHandle?
    private var backlog: [String] = []
    private var closed = false

    /// 起動直後に1回。F_SETNOSIGPIPE で親が SIGPIPE で落ちないようにする(ScenarioHost と同じ)
    func attach(_ handle: FileHandle) {
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        queue.async {
            guard !self.closed else { try? handle.close(); return }
            self.handle = handle
            let pending = self.backlog
            self.backlog = []
            for line in pending { Self.send(line, to: handle) }
        }
    }

    func write(line: String) {
        queue.async {
            guard !self.closed else { return }
            if let handle = self.handle { Self.send(line, to: handle) } else { self.backlog.append(line) }
        }
    }

    /// 閉じるのもキューの中(積んだ行を書いてから閉じる)。閉じた後の書き込みは捨てる
    func close() {
        queue.async {
            self.closed = true
            try? self.handle?.close()
            self.handle = nil
            self.backlog = []
        }
    }

    /// 積んだ書き込みが済むまで待つ(テスト用)
    func flush() { queue.sync {} }

    private static func send(_ line: String, to handle: FileHandle) {
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
}

extension DynamicDispatcher {
    /// 子の標準出力の1行を受ける共通の口。要求なら答え(または保留)、他の `{"ftWork"` 行も表示へ出さない。
    /// 戻り値 true = 消費した。行末の `\r`(pty)は落としてから見る
    func intercept(line: String, entry: Int, writer: ChildStdinWriter) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WorkQueueProtocol.isWorkLine(trimmed) else { return false }
        if let want = WorkQueueProtocol.decodeWant(trimmed),
           let reply = handle(want, fromEntry: entry) {
            writer.write(line: WorkQueueProtocol.encode(reply))
        }
        if let na = WorkQueueProtocol.decodeNotApplicable(trimmed) {
            writer.write(line: WorkQueueProtocol.encode(handleNotApplicable(na, fromEntry: entry)))
        }
        if let kept = WorkQueueProtocol.decodeKept(trimmed) { handleKept(kept, fromEntry: entry) }
        return true
    }
}
