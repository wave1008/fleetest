// DynamicSplit.swift
// マシンをまたぐ run で、空いたデバイスレーンに次のシナリオを今渡すか待たせるかの判定(RR-8.1)。
// 純粋関数: 時計も I/O も持たない。時刻[ms]は呼び手が決めた単調な1本の軸。
//
// 規則(ユーザー指示):
// - 候補 = そのレーンの platform で回せる待ちシナリオ。見込みの長い順(同着は ID 昇順 = LPT・決定的)
// - 候補を全部その順に、他レーン(他マシン + 同じマシンの他レーン)も含めて「空く時刻 + そのレーンでの見込み」が一番早いレーンへ
//   仮に積み(BacklogPlacement。同着はこのレーン)、このレーンに最初に積まれた候補を渡す。
//   候補が1本なら here = 今 + このレーンでの見込み <= alt = 他レーンの一番早い終わり、と同じ
// - 1本も積まれなければ待たせる(遅いマシンが終わり際に長いシナリオを取って全体を引き延ばさない)。
//   他レーンに控えている候補を数えずに比べると、控えの山を前に遅いレーンが待ち続ける
// - 安全弁: 他レーンが見込みの時刻を過ぎても空かないときは、超過した分だけ空く時刻を後ろへ倒す
//   (固まった速いレーンを遅いレーンが待ち続けない)。待たせた判断が変わりうる時刻は reconsiderAt で返す
// - クラスの寄せ方(RR-8.3): 束ねたクラスは束ねた先にだけ渡し、束ねたレーンへは次を必ず渡す。束ねる前のクラスは
//   1つの塊(1ジョブ)として比べる。group の無いシナリオだけの run は上の規則のまま
public enum DynamicSplit {

    /// 寄せる属性のクラス(RR-8.3)。name = クラス名。order = @Order の値(@RunInOrder のクラスだけ非 nil)
    public struct Group: Hashable, Sendable {
        public let name: String
        public let placement: ClassPlacement
        public let order: Int?
        public init(name: String, placement: ClassPlacement, order: Int? = nil) {
            self.name = name
            self.placement = placement
            self.order = order
        }
    }

    /// 配る単位。platform は呼び手が解決済み(未宣言は run の既定 platform。子の run と同じ規則)
    public struct Scenario: Hashable, Sendable {
        public let id: String
        /// バリアント(nil = バリアントの無い run)。実行の単位は ID × バリアント
        public let variant: String?
        public let platform: String
        public let group: Group?
        /// バリアントの宣言順(束ねたクラスの並び「バリアントごとに続けて」の鍵。バリアントの無い run では 0)
        public let variantRank: Int
        public init(id: String, variant: String?, platform: String, group: Group? = nil, variantRank: Int = 0) {
            self.id = id
            self.variant = variant
            self.platform = platform
            self.group = group
            self.variantRank = variantRank
        }
        public var unitKey: ScenarioUnitKey { ScenarioUnitKey(id: id, variant: variant) }
    }

    /// 単位の決定的な並び(ID 昇順 → バリアント名。同着の解き方の唯一の定義)
    static func idPrecedes(_ lhs: Scenario, _ rhs: Scenario) -> Bool {
        lhs.id != rhs.id ? lhs.id < rhs.id : (lhs.variant ?? "") < (rhs.variant ?? "")
    }

    /// マシン(エントリ)の中の1レーン(デバイス)。entry = FleetSplit.Estimator の entry 番号
    public struct Lane: Hashable, Sendable {
        public let entry: Int
        public let lane: String
        public let platform: String
        public init(entry: Int, lane: String, platform: String) {
            self.entry = entry
            self.lane = lane
            self.platform = platform
        }
    }

    /// レーンの今。busy = 回しているシナリオと渡した時刻[ms]。nil = 空いて次を待っている
    public struct LaneState: Sendable {
        public let lane: Lane
        public let busy: (scenario: Scenario, since: Double)?
        public init(lane: Lane, busy: (scenario: Scenario, since: Double)?) {
            self.lane = lane
            self.busy = busy
        }
    }

    public enum Decision: Equatable, Sendable {
        /// このシナリオ ID を渡す
        case assign(ScenarioUnitKey)
        /// 渡さず待たせる。この時刻[ms]になったら判断が変わりうる(nil = 他のレーンの知らせを待つだけ)
        case hold(reconsiderAt: Double?)
        /// このレーンが回せるシナリオはもう無い(レーンは終わる)
        case none
    }

    /// クラスの束ねた先(RR-8.3)。記帳は呼び手(DynamicDispatcher)が、渡した直後に record で行う
    public struct Bindings: Sendable, Equatable {
        /// @RunOnSingleMachine のクラス名 → エントリ番号
        public var machine: [String: Int] = [:]
        /// @RunOnSingleDevice / @RunInOrder のクラス名 → レーン
        public var device: [String: Lane] = [:]

        public init() {}

        /// group を持つシナリオのクラスを lane(のエントリ)へ束ねる。束縛済みのクラスは変えない
        public mutating func record(_ scenario: Scenario, to lane: Lane) {
            guard let group = scenario.group else { return }
            switch group.placement {
            case .singleMachine:
                if machine[group.name] == nil { machine[group.name] = lane.entry }
            case .singleDevice, .inOrder:
                if device[group.name] == nil { device[group.name] = lane }
            }
        }
    }

    /// 1ジョブ。ほとんどは1シナリオ。束ねる前のクラスは pending のメンバー全部を1つの塊にする(head = order 昇順 → ID の最初)
    private struct Job: Hashable {
        let head: Scenario
        let members: [Scenario]
        /// 束ねる前のクラスの塊なら、その寄せ方
        let chunk: ClassPlacement?
        /// 束縛済みの singleMachine のクラスのメンバーなら束縛先のエントリ
        let boundEntry: Int?
        /// 塊のメンバーの OS(singleMachine のエントリ検査用)
        let platforms: Set<String>
    }

    private static func precedes(_ lhs: Scenario, _ rhs: Scenario) -> Bool {
        if lhs.variantRank != rhs.variantRank { return lhs.variantRank < rhs.variantRank }
        let l = lhs.group?.order ?? Int.max, r = rhs.group?.order ?? Int.max
        return l != r ? l < r : idPrecedes(lhs, rhs)
    }

    public static func decide(
        for requester: Lane, now: Double, pending: [Scenario], lanes: [LaneState],
        estimateMs: (Scenario, Int) -> Double, lpt: Bool = true,
        bindings: Bindings = Bindings(), entryPlatforms: [Int: Set<String>] = [:],
        triedBy: [ScenarioUnitKey: Set<Int>]
    ) -> Decision {
        let sameOS = pending.filter { $0.platform == requester.platform }

        // 規則1: このレーンに束ねたクラスが残っていれば、他を挟まずその次を渡す
        for name in bindings.device.filter({ $0.value == requester }).keys.sorted() {
            if let next = sameOS.filter({ $0.group?.name == name }).min(by: precedes) { return .assign(next.unitKey) }
        }

        // 規則2: 他へ束ねたクラスは候補から外す。束ねる前の singleMachine のクラスは、全メンバーの OS を持たないエントリへ渡さない
        var jobs: [Job] = []
        var unbound: [String: [Scenario]] = [:]
        for scenario in sameOS {
            guard let group = scenario.group else {
                jobs.append(Job(head: scenario, members: [scenario], chunk: nil, boundEntry: nil, platforms: []))
                continue
            }
            switch group.placement {
            case .singleMachine:
                if let entry = bindings.machine[group.name] {
                    if entry == requester.entry {
                        jobs.append(Job(head: scenario, members: [scenario], chunk: nil, boundEntry: entry, platforms: []))
                    }
                } else {
                    unbound[group.name, default: []].append(scenario)
                }
            case .singleDevice, .inOrder:
                if bindings.device[group.name] == nil { unbound[group.name, default: []].append(scenario) }
            }
        }
        for members in unbound.values {
            let head = members.min(by: precedes)!
            let allPlatforms = Set(pending.filter { $0.group?.name == head.group?.name }.map(\.platform))
            jobs.append(Job(head: head, members: members, chunk: head.group!.placement, boundEntry: nil,
                            platforms: allPlatforms))
        }

        /// 同じ OS のそのエントリのレーン数(要求者を含む。最小 1)
        func laneCount(_ entry: Int) -> Int {
            var set = Set(lanes.map(\.lane).filter { $0.entry == entry && $0.platform == requester.platform })
            if requester.entry == entry { set.insert(requester) }
            return max(set.count, 1)
        }
        /// そのレーンでジョブを始めてから終わるまで[ms](nil = そのレーンへは渡せない)。
        /// 塊は重さ: singleMachine = 見込みの和 ÷ そのエントリの同じ OS のレーン数 / デバイスに寄せる = 和(1台なので割らない)
        func costOn(_ job: Job, _ lane: Lane) -> Double? {
            if let bound = job.boundEntry, bound != lane.entry { return nil }
            // 対象外で戻されたシナリオ(DR-214)は、試したエントリのレーンを置き場に数えない。数えると空いた速いレーンへ仮置きして
            // 保留し、そのレーンは取れず、空いたレーンは見直しの時刻も作らないので run が止まる(11/26 のフル E2E の E2E-Android で約 25 分止まった)
            if triedBy[job.head.unitKey]?.contains(lane.entry) == true { return nil }
            guard let chunk = job.chunk else { return estimateMs(job.head, lane.entry) }
            let sum = job.members.reduce(0) { $0 + estimateMs($1, lane.entry) }
            guard chunk == .singleMachine else { return sum }
            if let have = entryPlatforms[lane.entry], !job.platforms.isSubset(of: have) { return nil }
            return sum / Double(laneCount(lane.entry))
        }

        // lpt false(`--no-lpt`)= 候補を ID 順に試す。待つかどうかの比べ方は変えない
        let candidates = jobs.compactMap { job -> (job: Job, here: Double)? in
            costOn(job, requester).map { (job: job, here: $0) }
        }
            .sorted { lpt && $0.here != $1.here ? $0.here > $1.here : idPrecedes($0.job.head, $1.job.head) }
        if candidates.isEmpty { return .none }

        let others = lanes.filter { $0.lane.platform == requester.platform && $0.lane != requester }

        /// 他レーンが空く見込みの時刻。超過中は超過した分だけ後ろへ倒す(安全弁)
        func freeAt(_ state: LaneState) -> Double {
            guard let busy = state.busy else { return now }
            let expected = busy.since + estimateMs(busy.scenario, state.lane.entry)
            return expected >= now ? expected : now + (now - expected)
        }

        let placed = BacklogPlacement.place(
            jobs: candidates.map(\.job), requester: requester, requesterAvailable: now,
            workers: others.map { (worker: $0.lane, available: freeAt($0)) },
            cost: { job, lane in costOn(job, lane) })
        if let first = placed.first { return .assign(first.head.unitKey) }
        let placedOn = Dictionary(placed.placements.map { ($0.job, $0) }, uniquingKeysWith: { first, _ in first })

        // 規則が反転しうる最も早い時刻。空いている他レーンは時刻を作らない(そのレーンの要求で判断される)
        var reconsiderAt: Double?
        func consider(_ t: Double) {
            if t > now, t < (reconsiderAt ?? .infinity) { reconsiderAt = t }
        }
        for state in others {
            guard let busy = state.busy else { continue }
            let expected = busy.since + estimateMs(busy.scenario, state.lane.entry)
            // ちょうど今は超過の側で解く(> now の時刻しか採らないので、見込みの側だと時刻が作られずタイマーが消える。TargetSchedule と同じ)
            if expected > now {
                consider(expected)
            } else {
                // 超過中は alt も here も時刻に 1:1 で伸びるので、t + (t - expected) + B + estL >= t + estHere を解く。
                // B = 仮に積んだときその候補より先にそのレーンへ積まれた分(0 = 控えを数えない場合の時刻。早めに見直すのは害が無い)
                // 塊のジョブは重さ(costOn)でそのレーンの値を引く(代表1本の見込みだと時刻がずれる)
                for candidate in candidates {
                    guard let there = costOn(candidate.job, state.lane) else { continue }
                    let p = placedOn[candidate.job]
                    let base = expected + candidate.here - there
                    consider(base)
                    if let p, p.worker == state.lane {
                        consider(base - (p.availableBefore - freeAt(state)))
                    }
                }
            }
        }
        return .hold(reconsiderAt: reconsiderAt)
    }
}
