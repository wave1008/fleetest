import Foundation

/// 並列ワーカーへのシナリオ分配キュー(早い者勝ち)
actor ScenarioQueue {
    private var items: [ScenarioRunItem]
    private var attempts: [URL: Int] = [:]
    /// pulled(`ScenarioDispatch.pulled`)だけ。外の配り手から取る。shared / broadcast は nil
    private let pull: PullState?
    /// 配り手が nil を返したレーン(以後そのレーンは聞き直さない)。**レーンごとに持つ** —— 束ねたクラス(RR-8.3)があると
    /// 親は「残りは別のレーンに束ねた分だけ」のレーンにも nil を返すので、1つのレーンの nil を全レーンの尽きと読むと、
    /// 束ねたレーンが残りを聞きに行かずに終わり、そのクラスの残りが誰にも渡らない(回帰で実測: @RunInOrder の3本目)
    private var pullExhaustedLanes: Set<String> = []

    struct PullState: Sendable {
        let source: any ScenarioPullSource
        let platform: String
        /// シナリオ ID → 配れる item(同じ ID が複数あれば先頭から。計測の繰り返し展開)
        let catalog: LockedValue<[String: [ScenarioRunItem]]>
        /// 配った1本ごと(total を増やす)
        let onHandOut: @Sendable (ScenarioRunItem) async -> Void
        /// カタログに無い ID が来た(ワーカーログへ出して聞き直す)
        let onUnknownID: @Sendable (String) -> Void
    }

    /// デバイスに寄せたクラス(`placement.bindsDevice`)→ 最初の1本を取ったレーン(空文字 = レーン名の無い経路)。
    /// 束ねたレーンだけがそのクラスを取り、そのクラスの残りがあれば他を挟まず次に取る(RR-8.3)
    private var classLane: [String: String] = [:]
    /// @RunInOrder の失敗の後の記帳(pulled は配り手が以後もそのクラスを渡すので、渡されたものを `inOrderSkipReason` で止める)
    private var inOrderGate = InOrderGate()
    /// @RunInOrder のクラス → そのキューが初期化時に持っていたメンバー(実行順の注記の「何本中の何番目」の母数)
    private let inOrderMembers: [String: [ScenarioInfo]]

    init(_ items: [ScenarioRunItem]) {
        self.items = Self.arranged(items)
        self.pull = nil
        self.inOrderMembers = Self.groupInOrder(of: items.map(\.info))
    }
    init(pulled: PullState) {
        self.items = []
        self.pull = pulled
        self.inOrderMembers = Self.groupInOrder(of: pulled.catalog.withLock { $0.values.flatMap { $0 } }.map(\.info))
    }

    /// 寄せるクラスを連続させる(`ClassPlacementRules.ordered`)。属性が1つも無いキューは並びに触らない。
    /// 同じ ID の item(計測の繰り返し)は並べ直した順に1つずつ対応させる
    private static func arranged(_ items: [ScenarioRunItem]) -> [ScenarioRunItem] {
        guard items.contains(where: { $0.info.placement != nil }) else { return items }
        var byID: [String: [ScenarioRunItem]] = [:]
        for item in items { byID[item.info.id, default: []].append(item) }
        return ClassPlacementRules.ordered(items.map(\.info)).compactMap { info -> ScenarioRunItem? in
            guard var list = byID[info.id], !list.isEmpty else { return nil }
            let first = list.removeFirst()
            byID[info.id] = list
            return first
        }
    }

    private static func groupInOrder(of infos: [ScenarioInfo]) -> [String: [ScenarioInfo]] {
        Dictionary(grouping: infos.filter { $0.placement == .inOrder }) { ClassPlacementRules.className(of: $0.id) }
    }

    /// キューに渡すレーン名。**論理名が無い経路(`--port` 直指定)はラベル(ポート込みで一意)**にする —— 空のままだと全ワーカーが
    /// 同じ名前になり、デバイスに束ねたクラスを全員が「自分のレーン」と見なして同時に走らせる
    static func lane(of worker: RunWorker) -> String { worker.logicalName ?? worker.label }

    private static func className(_ item: ScenarioRunItem) -> String { ClassPlacementRules.className(of: item.info.id) }
    private static func bindsDevice(_ item: ScenarioRunItem) -> Bool { item.info.placement?.bindsDevice == true }

    /// 他のレーンに束ねたクラスの item か(このレーンは取らない)
    private func isBlocked(_ item: ScenarioRunItem, lane: String) -> Bool {
        guard Self.bindsDevice(item), let owner = classLane[Self.className(item)] else { return false }
        return owner != lane
    }

    private func take(at i: Int, lane: String) -> ScenarioRunItem {
        let item = items.remove(at: i)
        avoidedLane[item.id] = nil
        if Self.bindsDevice(item), classLane[Self.className(item)] == nil { classLane[Self.className(item)] = lane }
        return item
    }

    /// このキューを消化するレーン(`RunWorker.logicalName`)。参加でふやし、`laneEnded` で減らす。
    /// ブリッジ不達の振り直しが「落としたレーン以外」に空きがあるかを知るためだけに持つ
    private var liveLanes: Set<String> = []
    /// ブリッジ不達で振り直した item → それを落としたレーン。別のレーンが生きている間は、そのレーンへ戻さない
    private var avoidedLane: [URL: String] = [:]
    /// 避けられた item しか残っていないレーンが、別のレーンが取るのを待つ間の見直しの間隔。
    /// 他のレーンの空きを知らせるイベントが無いので見直すしかない(秒単位の待ちなので 0.2 秒で足りる・尽きる上限は無い =
    /// 別のレーンが全部終われば `laneEnded` で待ちが解ける)
    static let avoidedItemRecheckInterval: Duration = .milliseconds(200)

    func laneJoined(_ lane: String?) { if let lane, !lane.isEmpty { liveLanes.insert(lane) } }

    /// レーンが終わった。**そのレーンに束ねたクラスの残りを取り除いて返す**(別のレーンへ移さない = 移すと流し直しと残りが
    /// 2台で同時に走る)。呼び手が `ClassPlacementRules.orphanReason` で失敗として記録する。
    /// `orphaning: false`(中断で止まった)なら取り除かず、ドレインが中断として記録する
    @discardableResult
    func laneEnded(_ lane: String?, orphaning: Bool = true) -> [ScenarioRunItem] {
        if let lane { liveLanes.remove(lane) }
        guard orphaning else { return [] }
        let key = lane ?? ""
        let mine = Set(classLane.filter { $0.value == key }.keys)
        guard !mine.isEmpty else { return [] }
        let orphans = items.filter { Self.bindsDevice($0) && mine.contains(Self.className($0)) }
        items.removeAll { Self.bindsDevice($0) && mine.contains(Self.className($0)) }
        for name in mine { classLane[name] = nil }
        return orphans
    }

    /// 束ねたクラスの残りがあればそれを先に(他を挟まない)、無ければ他のレーンに束ねていない先頭
    private func takeAllowed(lane: String) -> ScenarioRunItem? {
        if !classLane.isEmpty {
            let mine = Set(classLane.filter { $0.value == lane }.keys)
            if !mine.isEmpty,
               let i = items.firstIndex(where: { Self.bindsDevice($0) && mine.contains(Self.className($0)) }) {
                return take(at: i, lane: lane)
            }
        }
        guard let i = items.firstIndex(where: {
            !isBlocked($0, lane: lane) && (lane.isEmpty || avoidedLane[$0.id] != lane)
        }) else { return nil }
        return take(at: i, lane: lane)
    }

    /// @RunInOrder のテストが失敗として確定した。同じクラスの手元の残りを取り除いて返し(呼び手が
    /// `notRunReason` で失敗として記録する)、以後このクラスが配り手から来ても `inOrderSkipReason` が止める
    func abandonInOrderClass(after item: ScenarioRunItem, lane: String?) -> [ScenarioRunItem] {
        guard item.info.placement == .inOrder else { return [] }
        inOrderGate.record(item.info, lane: lane ?? "", passed: false)
        let name = Self.className(item)
        let rest = items.filter { Self.className($0) == name }
        items.removeAll { Self.className($0) == name }
        return rest
    }

    /// 配り手から受け取った @RunInOrder のテストが、同じレーンで先に失敗したクラスのものなら実行しない理由
    func inOrderSkipReason(for item: ScenarioRunItem, lane: String?) -> String? {
        inOrderGate.skipReason(for: item.info, lane: lane ?? "")
    }

    /// @RunInOrder のテストの実行順の注記(何本中の何番目)。それ以外は nil
    func positionNotice(for item: ScenarioRunItem) -> String? {
        guard item.info.placement == .inOrder else { return nil }
        return ClassPlacementRules.positionNotice(item.info, classMembers: inOrderMembers[Self.className(item)] ?? [])
    }

    /// 再キューされたもの(pulled では常に先)→ 配り手。`lane` = `RunWorker.logicalName`(配り手が
    /// どのデバイスが空いたかを知るための名前)。shared / broadcast では配り手に使わない。
    /// **ブリッジ不達で振り直された item は、落としたレーン以外が生きている間そのレーンへ渡さない**
    /// (pulled で配り手に残りがあれば先にそちらを渡し、無ければ他のレーンが取るまで待つ。他のレーンが無ければ従来どおり渡す)。
    /// `shouldStop` が真なら待たずに nil(残りは手元に残る)
    func next(lane: String? = nil, shouldStop: (@Sendable () async -> Bool)? = nil) async -> ScenarioRunItem? {
        let lane = lane ?? ""
        while true {
            if let item = takeAllowed(lane: lane) { return item }
            if pull != nil, !pullExhaustedLanes.contains(lane) {
                if let item = await pullNext(lane: lane) { return item }
                // 返事を待つ間に別のレーンが離脱して再キューした分を拾う(拾わずに終わると、回せる健全なレーンが居たのに
                // ドレインで未実行の失敗になる)
                continue
            }
            // 残りが無いか、他のレーンに束ねたクラスだけなら待たずに終える
            guard let rest = items.firstIndex(where: { !isBlocked($0, lane: lane) }) else { return nil }
            // 残りは自分が落とした item だけ
            guard liveLanes.contains(where: { $0 != lane }) else { return take(at: rest, lane: lane) }
            if await shouldStop?() == true { return nil }
            try? await Task.sleep(for: Self.avoidedItemRecheckInterval)
        }
    }

    /// 配り手から1本。配り手が尽きたら nil
    private func pullNext(lane: String) async -> ScenarioRunItem? {
        guard let pull else { return nil }
        while !pullExhaustedLanes.contains(lane) {
            guard let id = await pull.source.next(platform: pull.platform, lane: lane) else {
                pullExhaustedLanes.insert(lane)
                return nil
            }
            let item = pull.catalog.withLock { catalog -> ScenarioRunItem? in
                guard var list = catalog[id], !list.isEmpty else { return nil }
                let first = list.removeFirst()
                catalog[id] = list
                return first
            }
            if let item {
                await pull.onHandOut(item)
                if Self.bindsDevice(item), classLane[Self.className(item)] == nil { classLane[Self.className(item)] = lane }
                return item
            }
            pull.onUnknownID(id)
        }
        return nil
    }

    /// 配り手へ聞かず手元の残りだけ(ドレイン用。shared では `next()` と同じ)
    func nextLocal() -> ScenarioRunItem? { items.isEmpty ? nil : items.removeFirst() }

    /// shared / broadcast: 手元に残りがあるか。pulled: 手元に残りがある、または配り手からまだ来うる
    /// `lane` を渡すと、他のレーンに束ねたクラスの残りは数えない(そのレーンが取れる残りだけ)
    func hasItems(lane: String? = nil) -> Bool {
        let own = lane.map { l in items.contains { !isBlocked($0, lane: l) } } ?? !items.isEmpty
        // lane 無しは「どのレーンもまだ尽きを聞いていない」とき配り手から来うるとみなす(1つでも尽きを聞いたら来ない側 = 以前の意味)
        let fromPull = pull != nil && (lane.map { !pullExhaustedLanes.contains($0) } ?? pullExhaustedLanes.isEmpty)
        return own || fromPull
    }

    /// 凍結による再実行。上限(MAX_FREEZE_RETRIES)まで item を末尾へ戻し、
    /// 何回目の再実行かを返す。上限超過なら nil(=もう再実行しない)。
    /// `avoiding` = 落としたレーン(ブリッジ不達の振り直しだけ渡す。`next` が別のレーンを優先する)。
    /// **デバイスに束ねたクラスの item は `avoiding` を掛けず、そのクラスの先頭へ戻す**(同じレーンが次に取る)
    func requeue(_ item: ScenarioRunItem, avoiding lane: String? = nil) -> Int? {
        let n = (attempts[item.id] ?? 0) + 1
        attempts[item.id] = n
        guard n <= MAX_FREEZE_RETRIES else { return nil }
        if Self.bindsDevice(item) {
            let name = Self.className(item)
            items.insert(item, at: items.firstIndex { Self.className($0) == name } ?? items.count)
            return n
        }
        if let lane, !lane.isEmpty { avoidedLane[item.id] = lane }
        items.append(item)
        return n
    }
}
