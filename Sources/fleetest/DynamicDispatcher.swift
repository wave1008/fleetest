// DynamicDispatcher.swift
// マシンをまたぐ run(`run` の DeviceMachineRunner / `api run` の ApiRunMachineFanout)で、子の
// `--work-queue` の要求(WorkQueueProtocol)を1か所で受け、DynamicSplit の規則で1本ずつ答える親の配り手(RR-8.1)。
//
// - 状態は全部 LockedValue の中。要求は子ごとの読み取りスレッド・タイマー・終了通知から並行に来る
// - 返事は臨界区間の外で送る(送り先の書き込みが詰まっても他の判断を止めない)
// - 子の stdin が `ssh -tt` の先では EOF が当てにならないので、**要求には必ず答える**(もう無ければ none)
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

    private struct State {
        var pending: [DynamicSplit.Scenario]
        /// 要求を出したことのあるレーンだけ(供給中のレーンを空きと数えない)。値 nil = 空いて返事待ち
        var lanes: [DynamicSplit.Lane: Busy?] = [:]
        var held: [Held] = []
        var assigned: [Int: [String]] = [:]
        var exited: Set<Int> = []
        var interrupted = false
        var cancelTimer: Cancel?
        /// 束ねた先(RR-8.3)。渡した直後に record する
        var bindings = DynamicSplit.Bindings()
        /// 臨界区間の中で積み、外(`withState`)で出す束ねたときの1行
        var logs: [String] = []
    }

    private let state: LockedValue<State>
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
         send: @escaping @Sendable (Int, WorkQueueProtocol.Reply) -> Void) {
        self.lpt = lpt
        self.entryPlatforms = entryPlatforms
        self.entryLabel = entryLabel
        self.log = log
        state = LockedValue(State(pending: scenarios))
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

    /// 子が終わった。そのレーンと保留中の要求を捨てる。渡し済みのシナリオは回し直さない
    func childExited(entry: Int) {
        let answers: [(Held, WorkQueueProtocol.Reply)] = withState { s in
            s.exited.insert(entry)
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

    func assignedIDs(entry: Int) -> [String] { state.withLock { $0.assigned[entry] ?? [] } }
    var assignedCounts: [Int: Int] { state.withLock { $0.assigned.mapValues(\.count) } }
    /// 誰にも渡さなかったシナリオ(全部の子が終わった後に読む)
    var unhandedIDs: [String] { state.withLock { $0.pending.map(\.id) } }
    var isInterrupted: Bool { state.withLock { $0.interrupted } }
    /// まだ誰にも渡していないシナリオ(複数対象の配り手 MultiTargetRunner が仕事の残りの見込みに使う。読むだけ)
    var pendingScenarios: [DynamicSplit.Scenario] { state.withLock { $0.pending } }

    /// 束ねた先のエントリが終わった(子が落ちた)ため、他へ移さずに残るシナリオ(RR-8.3。decide がもう他へ渡さない)
    var keptUnhanded: [(id: String, placement: ClassPlacement)] {
        state.withLock { s in
            s.pending.compactMap { scenario -> (id: String, placement: ClassPlacement)? in
                guard let group = Self.keptGroup(scenario, s) else { return nil }
                return (id: scenario.id, placement: group.placement)
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
    static func keptUnhandedLine(_ kept: [(id: String, placement: ClassPlacement)]) -> String? {
        guard !kept.isEmpty else { return nil }
        let attributes = Set(kept.map { $0.placement.attributeName }).sorted().joined(separator: ", ")
        let maxListed = 5
        let listed = kept.prefix(maxListed).map(\.id).joined(separator: ", ")
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
                let decision = DynamicSplit.decide(
                    for: held.lane, now: now, pending: s.pending, lanes: laneStates, estimateMs: estimateMs, lpt: lpt,
                    bindings: s.bindings, entryPlatforms: entryPlatforms)
                switch decision {
                case .assign(let id):
                    guard let index = s.pending.firstIndex(where: { $0.id == id }) else { continue }
                    let scenario = s.pending.remove(at: index)
                    if let group = scenario.group {
                        let wasBound = group.placement == .singleMachine
                            ? s.bindings.machine[group.name] != nil : s.bindings.device[group.name] != nil
                        s.bindings.record(scenario, to: held.lane)
                        if !wasBound { s.logs.append(keptLine(group, lane: held.lane)) }
                    }
                    s.lanes[held.lane] = .some(Busy(scenario: scenario, since: now))
                    s.assigned[held.lane.entry, default: []].append(id)
                    s.held.remove(at: position)
                    answers.append((held, .init(req: held.req, id: id)))
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

    static func resolve(_ scenarios: [(id: String, platform: String?)],
                        defaultPlatform: String) -> [DynamicSplit.Scenario] {
        scenarios.map { DynamicSplit.Scenario(id: $0.id, platform: $0.platform ?? defaultPlatform) }
    }

    /// 寄せる属性のクラスのシナリオには group を載せる(RR-8.3)。属性が無ければ上と同じ
    static func resolve(_ scenarios: [ScenarioInfo], defaultPlatform: String) -> [DynamicSplit.Scenario] {
        scenarios.map {
            DynamicSplit.Scenario(id: $0.id, platform: $0.platform ?? defaultPlatform, group: group(of: $0))
        }
    }

    static func group(of info: ScenarioInfo) -> DynamicSplit.Group? {
        guard let placement = info.placement else { return nil }
        return DynamicSplit.Group(name: ClassPlacementRules.className(of: info.id), placement: placement,
                                  order: info.order)
    }

    /// 静的な割り当て(FleetSplit.plan の groups:)用。キー = シナリオ ID
    static func groups(of infos: [ScenarioInfo]) -> [String: DynamicSplit.Group] {
        var result: [String: DynamicSplit.Group] = [:]
        for info in infos { if let g = group(of: info) { result[info.id] = g } }
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
    static func candidateIDs(for group: DeviceMachineRunner.Group,
                             in scenarios: [DynamicSplit.Scenario]) -> [String] {
        scenarios.filter { group.platforms.contains($0.platform) }.map(\.id)
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
        return true
    }
}
