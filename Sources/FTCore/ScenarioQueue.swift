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
        /// 単位(ID × バリアント)→ 配れる item(同じ単位が複数あれば先頭から。計測の繰り返し展開)
        let catalog: LockedValue<[ScenarioUnitKey: [ScenarioRunItem]]>
        /// 配った1本ごと(total を増やす)
        let onHandOut: @Sendable (ScenarioRunItem) async -> Void
        /// カタログに無い単位が来た(ワーカーログへ出して聞き直す)
        let onUnknownID: @Sendable (ScenarioUnitKey) -> Void
    }

    /// デバイスに寄せたクラス(`placement.bindsDevice`)→ 最初の1本を取ったレーン(空文字 = レーン名の無い経路)。
    /// 束ねたレーンだけがそのクラスを取り、そのクラスの残りがあれば他を挟まず次に取る(RR-8.3)。
    /// **鍵はクラス名のまま(バリアントを含めない)**: 寄せる属性のクラスはバリアントをまたいで同じ台に載せる(6.3)
    private var classLane: [String: String] = [:]
    /// @RunInOrder の失敗の後の記帳(pulled は配り手が以後もそのクラスを渡すので、渡されたものを `inOrderSkipReason` で止める)
    private var inOrderGate = InOrderGate()
    /// @RunInOrder のクラス × バリアント → そのキューが初期化時に持っていたメンバー(実行順の注記の「何本中の何番目」の母数。
    /// 母数はバリアントのまとまりの中で数える)
    private let inOrderMembers: [ClassVariantKey: [ScenarioInfo]]

    init(_ items: [ScenarioRunItem]) {
        self.items = Self.arranged(items)
        self.pull = nil
        self.inOrderMembers = Self.groupInOrder(of: items)
    }
    init(pulled: PullState) {
        self.items = []
        self.pull = pulled
        self.inOrderMembers = Self.groupInOrder(of: pulled.catalog.withLock { $0.values.flatMap { $0 } })
    }

    /// 寄せるクラスを連続させる(`ClassPlacementRules.ordered`。バリアントごとに続けて並べる)。属性が1つも無いキューは並びに触らない
    private static func arranged(_ items: [ScenarioRunItem]) -> [ScenarioRunItem] {
        guard items.contains(where: { $0.info.placement != nil }) else { return items }
        return ClassPlacementRules.ordered(items, info: \.info, variant: \.variant)
    }

    private static func groupInOrder(of items: [ScenarioRunItem]) -> [ClassVariantKey: [ScenarioInfo]] {
        var result: [ClassVariantKey: [ScenarioInfo]] = [:]
        for item in items where item.info.placement == .inOrder {
            result[classVariant(item), default: []].append(item.info)
        }
        return result
    }

    private static func classVariant(_ item: ScenarioRunItem) -> ClassVariantKey {
        ClassVariantKey(className: className(item), variant: item.variant)
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
        if !Self.bindsDevice(item) { running[lane] = item }
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

    /// 対象外(DR-214)の記帳。item → それを試して対象外と宣言したレーン。**回し直しの除外として効く**(`avoidedLane` の優先と違い、
    /// 別のレーンが居なくなっても戻さない = 戻すと同じ台で同じ対象外を繰り返す)
    private var triedLanes: [URL: Set<String>] = [:]
    /// item → 最後の対象外の宣言の理由(`.notRun` の失敗文言・ドレインの理由に使う)
    private var declaredReasons: [URL: String] = [:]
    /// 参加した後に終わった(離脱・尽き)レーン。再参加(`laneJoined`)で外す
    private var departedLanes: Set<String> = []
    /// レーン → いま走らせている**デバイスに束ねていない** item(`next` を呼んだ時点で空く)。ほかのレーンの対象外の結果が
    /// 自分へ戻ってくるかもしれない間、尽きたレーンが終わらずに待つための印
    private var running: [String: ScenarioRunItem] = [:]
    /// 配り手から来た item のうち、対象外で機械の中の別の台へ回し直している最中のもの(親へ `kept` を知らせた分)。
    /// 親はそのレーンの次の要求で配った単位を忘れるので、知らせないと他のマシンの尽きたレーンが待たずに終わる(DR-214 ②)
    private var keptUnits: Set<URL> = []

    /// レーン → 観測した種類(`RunWorker.deviceKind`。不明は載せない)。同じ種類のレーンは対象外を試した扱いになる
    private var laneKinds: [String: Set<String>] = [:]

    /// レーン → 台の性質(`RunWorker.effectiveTraits`。DR-237)。台の条件を持つ item を配るか・試した扱いにするかの判定の入力。
    /// 参加したことのあるレーンは離脱後も残す(結論の「使った台」)
    private var laneTraits: [String: DeviceTraits] = [:]

    /// 宣言されたのに参加しなかったレーン → 台の性質(nil = 観測していない)。ドレインの結論の入力(合う台が欠けただけで緑にしない)。
    /// 再参加(`laneJoined`)で外す
    private var absentLaneTraits: [String: DeviceTraits?] = [:]

    func laneJoined(_ lane: String?, kind: String? = nil, traits: DeviceTraits? = nil) {
        if let lane, !lane.isEmpty {
            liveLanes.insert(lane); departedLanes.remove(lane); absentLaneTraits[lane] = nil
            if let kind { laneKinds[lane] = [kind] } else { laneKinds[lane] = nil }
            if let traits { laneTraits[lane] = traits }
        }
    }

    /// 参加したことのあるレーンの性質(ドレインの結論の入力)
    func joinedLaneTraits() -> [DeviceRequirementMatch.Device] {
        laneTraits.keys.sorted().map { (id: $0, traits: laneTraits[$0]!) }
    }

    /// 参加しなかったレーン(結論の入力。性質が分かっていれば添える)
    func absentLanes() -> [DeviceRequirementGate.AbsentDevice] {
        absentLaneTraits.keys.sorted().map { (id: $0, traits: absentLaneTraits[$0] ?? nil) }
    }

    /// 宣言されたのに供給で合流しなかったレーン。何も試していない台が落ちたものとして数える(`laneJoined` で外れる)。
    /// 呼ぶのはそのレーンの供給が終わってから(供給中の台を数えると、遅れて合流する台へ回し直せるのに失敗にしてしまう)。
    /// `traits` = 親が観測した台の性質(nil = 読めなかった扱い)
    func laneNeverJoined(_ lane: String, traits: DeviceTraits? = nil) {
        guard !lane.isEmpty, !liveLanes.contains(lane) else { return }
        departedLanes.insert(lane)
        absentLaneTraits[lane] = .some(traits)
    }

    /// このレーンへ配らない item か。**台の条件に合わない・読めなかったレーンは配らない**(判定は `DeviceRequirementGate`。
    /// 条件の無い item は性質を見ない = 従来と同一)。その後に、対象外を試したレーン(DR-214)
    private func isExcluded(_ item: ScenarioRunItem, lane: String) -> Bool {
        if !DeviceRequirementGate.permits(item.info.deviceRequirements, traits: laneTraits[lane]) { return true }
        guard let tried = triedLanes[item.id] else { return false }
        return tried.contains(lane) || NotApplicableHandoff.covered(lane, tried: tried, kinds: laneKinds, evidence: triedKinds(item))
    }

    /// 他のレーンが走らせている item が、対象外で自分(未試行)へ戻ってくるかもしれないか
    private func othersMayHandBack(to lane: String) -> Bool {
        running.contains { $0.key != lane && liveLanes.contains($0.key) && !isExcluded($0.value, lane: lane) }
    }

    /// item が対象外で終わった(DR-214)。判定は `NotApplicableHandoff.decide`(機械をまたぐ親と同じ関数)。
    /// `.handOn` のときだけ item を除外つきで戻す(呼び手は記録を捨てる)。デバイスに束ねたクラス(`@RunInOrder` / `@RunOnSingleDevice`)は
    /// 別の台へ動かさず従来どおり `.skipped`
    func noteNotApplicable(_ item: ScenarioRunItem, lane: String?, reason: String) -> NotApplicableHandoff.Verdict {
        let lane = lane ?? ""
        triedLanes[item.id, default: []].insert(lane)
        declaredReasons[item.id] = reason
        guard !Self.bindsDevice(item) else { return .skipped }
        // 条件に合わないレーンは配られないので試した扱い(回し直しの先に数えない)
        let unfit = DeviceRequirementGate.ineligible(item.info.deviceRequirements, among: liveLanes.union(departedLanes),
                                                     traits: laneTraits)
        let verdict = NotApplicableHandoff.decide(tried: (triedLanes[item.id] ?? []).union(unfit), live: liveLanes,
            departed: departedLanes, kinds: laneKinds, evidence: triedKinds(item))
        if verdict == .handOn {
            items.append(item)
            // 機械の外へ出しうる item だけ(束ねたクラス・@RunOnSingleMachine は親へ問い合わせない = 親の待ちにも関わらない)
            if let pull, item.info.placement == nil, keptUnits.insert(item.id).inserted {
                pull.source.noteKept(unit: item.unitKey, on: true)
            }
        }
        return verdict
    }

    /// 試していない台が(このキューの中で)落ちているか。機械をまたぐ親へ問い合わせるときの申告(親の判定の `departed` に足される)
    func hasDepartedUntried(_ item: ScenarioRunItem) -> Bool {
        let unfit = DeviceRequirementGate.ineligible(item.info.deviceRequirements, among: departedLanes, traits: laneTraits)
        let tried = NotApplicableHandoff.effectiveTried(tried: (triedLanes[item.id] ?? []).union(unfit), among: departedLanes,
                                                        kinds: laneKinds, evidence: triedKinds(item))
        return !departedLanes.subtracting(tried).isEmpty
    }

    /// item を試して対象外と答えたレーンで観測した種類(レーン = 1台なので、そのレーンの種類が証拠になる)。親への問い合わせにも載せる
    func triedKinds(_ item: ScenarioRunItem) -> Set<String> {
        (triedLanes[item.id] ?? []).reduce(into: Set<String>()) { $0.formUnion(laneKinds[$1] ?? []) }
    }

    /// 親の配り手につながっているときだけ(対象外を機械の外へ回せるか聞く相手)
    func pullTarget() -> (source: any ScenarioPullSource, platform: String)? {
        pull.map { (source: $0.source, platform: $0.platform) }
    }

    func declaredReason(for item: ScenarioRunItem) -> String? { declaredReasons[item.id] }

    /// レーンが終わった。**そのレーンに束ねたクラスの残りを取り除いて返す**(別のレーンへ移さない = 移すと流し直しと残りが
    /// 2台で同時に走る)。呼び手が `ClassPlacementRules.orphanReason` で失敗として記録する。
    /// `orphaning: false`(中断で止まった)なら取り除かず、ドレインが中断として記録する
    @discardableResult
    func laneEnded(_ lane: String?, orphaning: Bool = true) -> [ScenarioRunItem] {
        if let lane {
            liveLanes.remove(lane)
            settleRunning(lane: lane)
            if !lane.isEmpty { departedLanes.insert(lane) }
        }
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
            !isBlocked($0, lane: lane) && !isExcluded($0, lane: lane) && (lane.isEmpty || avoidedLane[$0.id] != lane)
        }) else { return nil }
        return take(at: i, lane: lane)
    }

    /// @RunInOrder のテストが失敗として確定した。同じクラスの手元の残りを取り除いて返し(呼び手が
    /// `notRunReason` で失敗として記録する)、以後このクラスが配り手から来ても `inOrderSkipReason` が止める
    func abandonInOrderClass(after item: ScenarioRunItem, lane: String?) -> [ScenarioRunItem] {
        guard item.info.placement == .inOrder else { return [] }
        inOrderGate.record(item.info, variant: item.variant, lane: lane ?? "", passed: false)
        // 止めるのは同じバリアントのまとまりの中だけ(他のバリアントのまとまりは続ける)
        let key = Self.classVariant(item)
        let rest = items.filter { Self.classVariant($0) == key }
        items.removeAll { Self.classVariant($0) == key }
        return rest
    }

    /// 配り手から受け取った @RunInOrder のテストが、同じレーンで先に失敗したクラスのものなら実行しない理由
    func inOrderSkipReason(for item: ScenarioRunItem, lane: String?) -> String? {
        inOrderGate.skipReason(for: item.info, variant: item.variant, lane: lane ?? "")
    }

    /// @RunInOrder のテストの実行順の注記(何本中の何番目)。それ以外は nil
    func positionNotice(for item: ScenarioRunItem) -> String? {
        guard item.info.placement == .inOrder else { return nil }
        return ClassPlacementRules.positionNotice(item.info, classMembers: inOrderMembers[Self.classVariant(item)] ?? [])
    }

    /// 再キューされたもの(pulled では常に先)→ 配り手。`lane` = `RunWorker.logicalName`(配り手が
    /// どのデバイスが空いたかを知るための名前)。shared / broadcast では配り手に使わない。
    /// **ブリッジ不達で振り直された item は、落としたレーン以外が生きている間そのレーンへ渡さない**
    /// (pulled で配り手に残りがあれば先にそちらを渡し、無ければ他のレーンが取るまで待つ。他のレーンが無ければ従来どおり渡す)。
    /// `shouldStop` が真なら待たずに nil(残りは手元に残る)
    func next(lane: String? = nil, shouldStop: (@Sendable () async -> Bool)? = nil) async -> ScenarioRunItem? {
        let lane = lane ?? ""
        settleRunning(lane: lane)
        while true {
            running[lane] = nil
            if let item = takeAllowed(lane: lane) { return item }
            // 手元で回し直し中(親へ `kept` を知らせた)の item を別のレーンが走らせていて、自分がまだ試していないなら、親へ頼まず手元で待つ
            // (DR-214 ②)。親は他のマシンの回し直しを理由に要求を保留しうるので、頼むと対象外で戻ってくる item を取れるレーンが減り、
            // 2台のマシンが互いの回し直しを待ち合う形に近づく。保留中に回し直しが始まった分は親が `recheck` で起こす
            if pull != nil, awaitsKeptItem(lane: lane) {
                if await shouldStop?() == true { return nil }
                try? await Task.sleep(for: Self.avoidedItemRecheckInterval)
                continue
            }
            if pull != nil, !pullExhaustedLanes.contains(lane), !parkedUnitAwaitsAnotherLane(lane) {
                if let item = await pullNext(lane: lane) { return item }
                // 返事を待つ間に別のレーンが離脱して再キューした分を拾う(拾わずに終わると、回せる健全なレーンが居たのに
                // ドレインで未実行の失敗になる)
                continue
            }
            // 残りが無いか、他のレーンに束ねたクラスだけなら、他のレーンの対象外の結果が戻ってくる見込みが無い限り待たずに終える
            let candidates = items.indices.filter { !isBlocked(items[$0], lane: lane) }
            if candidates.isEmpty {
                guard othersMayHandBack(to: lane) else { return nil }
            } else {
                let takeable = candidates.filter { !isExcluded(items[$0], lane: lane) }
                if takeable.isEmpty {
                    // 残りは自分が試して対象外だった item だけ。ほかに取れるレーンが居なければ手元に残す(ドレインが実行しなかった赤にする)
                    let someoneElse = candidates.contains { index in
                        liveLanes.contains { $0 != lane && !isExcluded(items[index], lane: $0) }
                    }
                    guard someoneElse else { return nil }
                } else if !liveLanes.contains(where: { $0 != lane }) {
                    // 残りは自分が落とした item だけ
                    return take(at: takeable[0], lane: lane)
                }
            }
            if await shouldStop?() == true { return nil }
            try? await Task.sleep(for: Self.avoidedItemRecheckInterval)
        }
    }

    /// 手元に、このレーンは取れず別の生きているレーンが取れる台の条件つきの item があるか。
    /// pulled で合わない単位を引いたレーンが聞き直し続けると、他のマシンの合う台が取れた単位まで溜め込む(配った数は進むのに走らない)。
    /// 取れる台が手元に居ないときは false(従来どおり聞き直す = そこで止めても誰も取らない)。
    /// 代償: 待つ間このレーンは条件の無い単位も引かない(合うレーンが取れば再開)
    private func parkedUnitAwaitsAnotherLane(_ lane: String) -> Bool {
        items.contains { item in
            guard let requirements = item.info.deviceRequirements, !requirements.isEmpty,
                  !DeviceRequirementGate.permits(requirements, traits: laneTraits[lane]) else { return false }
            return liveLanes.contains { $0 != lane && DeviceRequirementGate.permits(requirements, traits: laneTraits[$0]) }
        }
    }

    /// 別のレーンが走らせている回し直し中の item を、このレーンがまだ試していないか
    private func awaitsKeptItem(lane: String) -> Bool {
        running.contains { other, item in
            other != lane && liveLanes.contains(other) && keptUnits.contains(item.id) && !isExcluded(item, lane: lane)
        }
    }

    /// レーンの走らせていた item が終わった。回し直し中と親へ知らせた item が、手元のどこにも残っていなければ(回し直しで
    /// 戻っていない・別のレーンが走らせていない)回し直しの終わりを知らせる。親へ対象外を問い合わせた分は親が先に忘れている(重ねて害は無い)
    private func settleRunning(lane: String) {
        guard let item = running.removeValue(forKey: lane), keptUnits.contains(item.id),
              !items.contains(where: { $0.id == item.id }), !running.values.contains(where: { $0.id == item.id }) else { return }
        keptUnits.remove(item.id)
        pull?.source.noteKept(unit: item.unitKey, on: false)
    }

    /// 配り手から1本。配り手が尽きたら nil
    private func pullNext(lane: String) async -> ScenarioRunItem? {
        guard let pull else { return nil }
        while !pullExhaustedLanes.contains(lane) {
            let unit: ScenarioUnitKey
            switch await pull.source.next(platform: pull.platform, lane: lane) {
            case .exhausted:
                pullExhaustedLanes.insert(lane)
                return nil
            case .recheck:
                // 呼び手(`next`)が手元のキューを見直してから聞き直す
                return nil
            case .unit(let given):
                unit = given
            }
            let item = pull.catalog.withLock { catalog -> ScenarioRunItem? in
                guard var list = catalog[unit], !list.isEmpty else { return nil }
                let first = list.removeFirst()
                catalog[unit] = list
                return first
            }
            if let item {
                await pull.onHandOut(item)
                // 条件に合わないレーンへ配られた単位は、このレーンで走らせず手元に戻す(合うレーンが取るか、無ければドレインの結論)
                if !DeviceRequirementGate.permits(item.info.deviceRequirements, traits: laneTraits[lane]) {
                    items.append(item)
                    // 親へ返す口は無い(`declareNotApplicable` は「試して対象外」の意味で、親は緑の対象外に確定しうる)ので、
                    // 手元の別のレーンが取れるなら、取られるまでこのレーンは聞き直さない = 溜め込まない(上限 1 本)
                    if parkedUnitAwaitsAnotherLane(lane) { return nil }
                    continue
                }
                if Self.bindsDevice(item), classLane[Self.className(item)] == nil { classLane[Self.className(item)] = lane }
                if !Self.bindsDevice(item) { running[lane] = item }
                return item
            }
            pull.onUnknownID(unit)
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
