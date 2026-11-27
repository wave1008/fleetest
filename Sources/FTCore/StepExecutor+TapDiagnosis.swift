// StepExecutor+TapDiagnosis.swift
// 失敗したステップに付ける、直前の tap の診断(飲まれた・対象が動いた・覆われた)と探す範囲の案内の文言。
// 本体は StepExecutor.swift(instance 状態はそちらに置く)

import Foundation

extension StepExecutor {
    /// 救済の送りの後も掴んだ要素が座標のクランプされた残骸(同じ点に中身のある要素が積み重なる = 注記の stacked と同じ
    /// `OcclusionGeometry.stackedRefs`)のままのとき、撃たずに返す失敗文(DR-188)。その点に描かれているのは別の物で、撃つと
    /// 別の画面が開いて ✅ になった(iOS 連絡先の編集フォーム・XCUITest の木)
    static func stackedLeftoverRefusal(_ step: FlowStep, target: ElementInfo, trace: [String]) -> String {
        "did not touch \(step.locatorSummary): it resolved to \(TapTargetGeometry.describe(target)), which is still reported"
            + " outside its scroll container with clamped coordinates (stacked on the same spot as other elements), so a touch there"
            + " would land on whatever is drawn at that point (nothing was touched). Scroll the list until it is drawn first"
            + " (for example scrollTo or scrollToBottom()) and then touch it"
            + (trace.isEmpty ? "" : " [rescue: " + trace.joined(separator: "; ") + "]")
    }

    /// 2つの木の内容が同じか(`contentSignature`)
    public static func sameContent(_ a: [ElementInfo], _ b: [ElementInfo]) -> Bool {
        contentSignature(a) == contentSignature(b)
    }

    /// 木の内容署名(**位置だけでなくラベル・値も含む**)。
    ///
    /// `settledSignature` の署名とは別物なので共用しないこと —— あちらは「動いているか」を見るので
    /// frame だけ(iOS の再利用セルはラベルが振れるため入れると収束しない)。こちらは
    /// 「何か変わったか」を見るので、**レイアウトが同じでテキストだけ変わる更新**
    /// (`selected=-` → `selected=row_30` がまさにこれ)を取りこぼしてはいけない。
    /// ラベルの振れは「変わった」側に倒れる = 誤って「無変化」と言うことはない(片側の誤りしか出ない)
    static func contentSignature(_ elements: [ElementInfo]) -> String {
        var text = ""
        text.reserveCapacity(elements.count * 48)
        for element in elements {
            let frame = element.frame
            text += "\(element.type)|\(element.identifier ?? "")|\(element.label ?? "")"
            text += "|\(element.value ?? "")|\(element.enabled)|\(element.checked ?? false)"
            text += "|\(Int(saturating: frame.x)),\(Int(saturating: frame.y)),\(Int(saturating: frame.width)),\(Int(saturating: frame.height));"
        }
        return text
    }

    /// 直前のタップについて、失敗した側の木から**分かることだけ**を失敗文言へ添える。
    /// **判定には触れない**(正しく変化しない操作もあるので、理由付けにだけ使う)。
    /// 呼び手は**既に持っている木の要素列**を渡すこと(このために追加取得しない)。
    ///
    /// 出るのは排他な2つ。**この2つを分けることが目的**で、事後の幾何だけでは区別できない
    /// (実際に取り違えた: 失敗時に対象が容器の縁へずれていたのを「掴んだ時点で
    /// 壊れていた」と読み、探索側を直したが**一度も発火しなかった**):
    ///   1. **木が1ピクセルも変わっていない** → タップが丸ごと飲まれた(真の空振り)
    ///   2. **対象があの後動いた** → タップは**動く前の座標**を撃った可能性(古い座標)
    ///
    /// StepExecutor+Assert.swift の失敗経路から呼ぶため internal
    func tapDiagnosisHint(_ elements: [ElementInfo]?) -> String {
        let last = lastTapHint(elements)
        let earlier = stillUnchangedEarlierTaps(unchangedEarlierTaps, at: elements)
        if last.unchanged || !earlier.isEmpty {
            noteCodesThisStep.insert(.unchangedTapBeforeFailure)
        }
        return last.text + coveredTouchHint() + earlierTapsHint(earlier)
    }

    /// 前のタップのうち、**失敗側の木がまだそのタップの時点の木と同じもの**だけ残す。違えば、その後に画面が変わった
    /// (遅れて効いた・別の scene へ移った)ので「飲まれたかも」と挙げない。木が無ければ比べられないので全部残す。返すのは呼び名
    func stillUnchangedEarlierTaps(_ taps: [UnchangedTap], at elements: [ElementInfo]?) -> [String] {
        guard let elements, !taps.isEmpty else { return taps.map(\.description) }
        let now = Self.contentSignature(elements)
        return taps.filter { $0.signature == now }.map(\.description)
    }

    /// 覆いの名指しを抑える組(`OccluderNaming`)に使う材料。**判定と撃ち方には使わない**(文言と案内だけ)
    /// 塗り順は、その木について控えた答えがあるときだけ載せる(`paintRanksCache`。取りに行くのは `resolvingPaintOrder`)
    func occluderNaming(for elements: [ElementInfo]) -> OccluderNamingContext {
        let ranks = paintRanksCache.flatMap { $0.signature == Self.contentSignature(elements) ? $0.answer : nil }
        return OccluderNamingContext(isAndroid: isAndroid, framework: uiFramework, paintRanks: ranks)
    }

    /// 名指しの出口の計算を、塗り順の答え無しで1回 → 名指しを抑えた(`suppressed`)ときだけ答えを取りに行って計算し直す(DR-235)。
    /// **普通のタップに往復を足さない** = 聞くのは今の規則で名指せない組がある回だけ(Android の Flutter・同じ仮想の土台の中の組)。
    /// ブリッジの ref は直近の木の中でだけ有効なので、**木を撮った直後(撃つ前)の呼び手だけが聞く**(`fetch: false` は控えだけ使う)。
    /// 答えの木が違えば `PaintRankAnswer.make` が捨てる
    func resolvingPaintOrder<R>(_ snapshot: SnapshotResponse, fetch: Bool,
                                _ compute: (OccluderNamingContext) -> R, suppressed: (R) -> Bool) async -> R {
        let base = OccluderNamingContext(isAndroid: isAndroid, framework: uiFramework, paintRanks: nil)
        let first = compute(base)
        guard suppressed(first) else { return first }
        if fetch { _ = await paintRanks(for: snapshot) }
        let naming = occluderNaming(for: snapshot.elements)
        guard naming.paintRanks != nil else { return first }
        let again = compute(naming)
        if !suppressed(again) { noteCodesThisStep.insert(.occluderOrderFromSemantics) }
        return again
    }

    /// その木の塗り順の答え(DR-235)。控えが無ければ聞く(Android だけ)。**呼ぶのは木を撮った直後(撃つ前・検証の段)だけ** ——
    /// ブリッジの ref は直近の木の中でだけ有効(違えば `make` が捨てる)。答えの木が違った回は控えない(同じ内容の木で次に聞けば合いうる)
    func paintRanks(for snapshot: SnapshotResponse) async -> PaintRankAnswer? {
        await paintRanks(elements: snapshot.elements, app: snapshot.sessionBundleID)
    }

    /// `app` = 木のアプリ(`sessionBundleID`。無ければ起こしたアプリ)。VM サービスが無いと答えたアプリの控えの鍵
    func paintRanks(elements: [ElementInfo], app: String?) async -> PaintRankAnswer? {
        guard isAndroid else { return nil }
        let signature = Self.contentSignature(elements)
        if let cached = paintRanksCache, cached.signature == signature { return cached.answer }
        let response = await askSemanticsOrder(elements: elements, app: app)
        let answer = PaintRankAnswer.make(response: response, elements: elements)
        if answer == nil {
            noteCodesThisStep.insert(.semanticsOrderUnavailable)
            traceThisStep.append(.semanticsOrder, ["outcome": "unavailable", "reason": Self.unavailableReason(response)])
            // ブリッジが答えられないと言い、その答えを控えた回だけ控える(木の食い違い・1回目の一時的な理由は控えない)
            if let reason = response?.reason,
               semanticsOrderCache?.signature == signature || Self.lastingReasons.contains(reason) { paintRanksCache = (signature, nil) }
        } else {
            traceThisStep.append(.semanticsOrder, ["outcome": "answered"])
            paintRanksCache = (signature, answer)
        }
        return answer
    }

    /// 足跡の理由: ブリッジの語彙(`reason`)か、ホストで使えなかった理由(no-response = 答えが返らない・旧ブリッジ /
    /// unusable-answer = 答えの中心がホストの木と合わない・ダンプに対応する要素が無い)
    static func unavailableReason(_ response: SemanticsOrderResponse?) -> String {
        guard let response else { return "no-response" }
        return response.reason ?? "unusable-answer"
    }

    /// ブリッジの `POST /semanticsorder` を聞く唯一の口。同じ木なら控えを返す・VM サービスが無いと答えたアプリへは聞かない。
    /// **ダンプを使う呼び手も `PaintRankAnswer.make` が通った答えだけを信じる**(ダンプは聞いた瞬間のもの = 木と同じ時点かは中心の照合でしか言えない)
    func askSemanticsOrder(elements: [ElementInfo], app: String?) async -> SemanticsOrderResponse? {
        let signature = Self.contentSignature(elements)
        if let cached = semanticsOrderCache, cached.signature == signature { return cached.response }
        if let miss = semanticsOrderTransientMisses[signature], miss.count >= 2 { return miss.response }
        // アプリが分からない木(`sessionBundleID` が無い)では控えを引かず、残さない(起こしたアプリで代用すると、別のアプリの答えで
        // 起こしたアプリを「VM サービス無し」と覚える)
        if let known = semanticsOrderUnavailableApp, known == app {
            return SemanticsOrderResponse(dump: nil, nodes: nil, reason: Self.noVMServiceReason)
        }
        let response = await driver.semanticsOrder()
        if response?.reason == Self.noVMServiceReason, let app { semanticsOrderUnavailableApp = app }
        // 控えるのは、ブリッジが答えられないと言った回と、答えがこの木のもの(中心が合う)回だけ。食い違った答えは控えない
        // (同じ内容の木を次に撮れば、ブリッジの直近の木と合いうる)。理由付きの答えはブリッジの直近の木についてで、ホストの木と同じかは
        // 確かめられない(別の呼び手が間に撮った木の答えが混ざりうる)が、倒れる先は答え無し = DR-230 のまま

        // 一時的な理由(締め切り・ダンプの失敗等)は同じ木でもう1回だけ聞く(たまたま遅かった1回で、その画面の間ずっと答え無しにしない)。
        // 2回続けば控える(同じ画面で毎回締め切りを払わない = 払うのは1画面あたり最大2回)
        if let reason = response?.reason, !Self.lastingReasons.contains(reason) {
            let count = (semanticsOrderTransientMisses[signature]?.count ?? 0) + 1
            semanticsOrderTransientMisses[signature] = (count, response)
            guard count >= 2 else { return response }
        }
        if response?.reason != nil || PaintRankAnswer.make(response: response, elements: elements) != nil {
            semanticsOrderCache = (signature, response)
        }
        return response
    }

    /// ブリッジの理由の語彙(FlutterSemanticsOrder.java の REASON_NO_VM_SERVICE と同じ綴り。`SemanticsOrderWireSyncTests`)
    public static let noVMServiceReason = "no-vm-service"
    /// 聞き直しても変わらない理由(木の形・アプリのビルド)。これ以外(no-snapshot / no-pid / dump-failed / timeout / empty-dump)は一時的。
    /// 綴りは FlutterSemanticsOrder.java の REASON_*(`SemanticsOrderWireSyncTests`)
    static let lastingReasons: Set<String> = ["no-virtual-nodes", "multiple-hosts", noVMServiceReason]

    /// `TapTargetGeometry.occlusionAdvisory` の文言を返し、名指しを抑えたら事実として注記 `occluderNamingSuppressed` を残す
    func occlusionAdvisoryNoted(for element: ElementInfo, in snapshot: SnapshotResponse) async -> String? {
        let result = await resolvingPaintOrder(snapshot, fetch: true, {
            TapTargetGeometry.occlusionAdvisoryResult(for: element, in: snapshot.elements, screen: snapshot.screen, naming: $0)
        }, suppressed: \.namingSuppressed)
        if result.namingSuppressed { noteCodesThisStep.insert(.occluderNamingSuppressed) }
        return result.text
    }

    /// `coveringHint` を実行機の OS・アプリの答えで呼び、名指しを抑えたら注記を残す。失敗の木 = ブリッジの直近の木とは限らないので
    /// 塗り順は控えだけを使う(聞かない)
    func coveringHintNoted(element: ElementInfo?, elements: [ElementInfo], screen: FTRect) -> String {
        let result = Self.coveringHintResult(element: element, elements: elements, screen: screen,
                                             naming: occluderNaming(for: elements))
        if result.namingSuppressed { noteCodesThisStep.insert(.occluderNamingSuppressed) }
        return result.hint
    }

    /// 直前の触る操作が覆いの重なった疑いのまま撃たれていたら、それを名指して直し方を言う(失敗のときだけ呼ばれる)。
    /// **原因と断定しない**(「それが原因なら」)。重なりは画面の大きさで変わるので、直すのは出たデバイスを見た利用者
    func coveredTouchHint() -> String {
        guard let last = lastInteraction else { return "" }
        guard let cover = last.coverSuspect else {
            if let axHit = last.axHitSuspect, !last.coverSuspectSuppressed {
                return " (when the preceding \(last.description) was fired, the accessibility hit test at the target's centre answered"
                    + " \(axHit), so the touch may have landed on it instead — if that is why this step failed, fix the scenario so the"
                    + " target is not covered at that step)"
            }
            guard last.coverSuspectSuppressed else { return "" }
            // 名指しを抑えた組(DR-230)は相手の名前を言わずに疑いだけ言う
            noteCodesThisStep.insert(.occluderNamingSuppressed)
            return " (when the preceding \(last.description) was fired, another element may have overlapped the target's"
                + " centre on this device (this app's accessibility tree does not tell which one is drawn in front), so the"
                + " touch may have landed on it instead — if that is why this step failed, check with a screenshot and fix the"
                + " scenario so the target is not covered at that step)"
        }
        noteCodesThisStep.insert(.coveredTouchBeforeFailure)
        return " (when the preceding \(last.description) was fired, \(cover) overlapped the target's centre on this device,"
            + " so the touch may have landed on \(cover) instead — if that is why this step failed, fix the scenario so the"
            + " target is not covered at that step. \(Self.uncoverRemedy(cover: cover, step: nil)))"
    }

    /// 次のタップの時点で画面が変わっていなかった、それより前のタップ(`unchangedEarlierTaps`)。
    /// 直前のタップの結果とは独立に添える —— 直前のタップが「画面を変えないのが正常」な操作でも、
    /// その前のタップが効いていなかった事実は消さない
    private func earlierTapsHint(_ taps: [String]? = nil, also: Bool = true, nextAction: String = "the tap") -> String {
        let taps = taps ?? unchangedEarlierTaps.map(\.description)
        guard !taps.isEmpty else { return "" }
        let names = taps.joined(separator: ", then ")
        return " (earlier, the screen was\(also ? " also" : "") unchanged between \(names) and \(nextAction) after it"
            + " — that interaction may have been swallowed\(outOfAppCaveat))"
    }

    /// 「見つからない」の失敗に添える: スコープの容器は見つかったが、木の上で中身を持たない(判定は
    /// `LocatorResolver.childlessScopeContainer`。MCP の `ft_tap` 等の selector の断りと共有)。木が無ければ空
    /// 理由は木の形と OS から言えるものだけ(葉の型なら「中身を持たない型」・iOS の入れ物の型だけ CMP の平坦化)。例は一般形
    /// (特定のアプリの id を出さない)
    /// **スコープが原因の「見つからない」の理由**(容器に中身が無い → 容器が木に無い → 対象がスコープの外に居る)。どれでもなければ ""。
    /// どれも待っても送っても閉じても直らない事実なので、tap・検証・送りの探索の失敗文はこれを言うときほかの案内(待ち・送り・覆い・
    /// 自分のダイアログ)を添えない(58周目: 「スコープの外」の後に scroll: / waitSeconds: / 閉じろが続いた・検証は言わなかった)。
    /// 対象がスコープの外に居るときは近い候補も挙げない(`LocatorResolver.candidateHint`)
    /// 送りの探索の失敗に添えるスコープの理由。`scopeReasonHint` に加えて、**容器も対象も木に無い**ときも言う(探索はもう送って待った後 =
    /// 容器が無ければ何も探せなかったのは事実。言わないとシートを広げろ・閉じろの案内へ落ちた = 59周目 iultra F2)。
    /// 送りの無い操作・検証では言わない(容器が読み込み中なら待てば出る = 待ちの案内を消さない)
    static func searchScopeHint(_ step: FlowStep, _ elements: [ElementInfo]?, isAndroid: Bool) -> String {
        let reason = scopeReasonHint(step, elements, isAndroid: isAndroid)
        guard reason.isEmpty, let locator = step.locator, let elements, !(locator.scope ?? []).isEmpty,
              LocatorResolver.scopedPool(locator.scope, elements: elements) == nil else { return reason }
        return " (the scope's container is not in the tree after the search either, so there was nothing to search inside —"
            + " check the container's selector, or make sure the container is on this screen)"
    }

    static func scopeReasonHint(_ step: FlowStep, _ elements: [ElementInfo]?, isAndroid: Bool) -> String {
        let childless = childlessScopeHint(step, elements, isAndroid: isAndroid)
        if !childless.isEmpty { return childless }
        guard let locator = step.locator, let elements,
              let target = LocatorResolver.targetOutsideScope(locator, in: elements) else { return "" }
        let named = LocatorResolver.nearMatchSummary(target)
        if LocatorResolver.scopedPool(locator.scope, elements: elements) == nil {
            return " (the target itself is in the tree (\(named)), but the scope's container is not, so waiting, scrolling or"
                + " closing anything will not help — drop the scope, or name a container that holds the target)"
        }
        return " (the target itself is in the tree (\(named)) but not inside the scope, so waiting or scrolling will not bring it in"
            + " — drop the scope, or name the container that holds the target)"
    }

    static func childlessScopeHint(_ step: FlowStep, _ elements: [ElementInfo]?, isAndroid: Bool) -> String {
        guard let locator = step.locator, let elements,
              let container = LocatorResolver.childlessScopeContainer(of: locator, in: elements) else { return "" }
        let reason: String
        if !LocatorResolver.childlessContainerIsGroup(container) {
            reason = " — it is \(EnglishArticle.indefinite(container.type)), which holds no other elements"
        } else if !isAndroid {
            reason = " — on iOS, Compose Multiplatform lists the contents of a Row/Column that only has a testTag beside it rather than under it"
        } else {
            reason = ""
        }
        return " (the scope's container \(TapTargetGeometry.describe(container)) is in the tree but has nothing under it,"
            + " so nothing can be found inside it\(reason). Point at the target without this scope: a unique #id, a label,"
            + " or a relative selector from an element next to it (e.g. #<id of a neighbour>:right))"
    }

    /// 操作の対象が解決できなかった失敗に添える(検証の失敗の `tapDiagnosisHint` と同じ証跡)。この手が tap なら直前の tap は
    /// 手の入口で控えたもの(`tapEvidenceAtEntry`)を使い、まだ比べていない直前の tap は解決に使った木と比べて足す。**追加の撮影はしない・タップの記録は変えない**。
    /// 名指しした回はステップの注記の印(`unchangedTapBeforeFailure`)を立てる = 失敗の文面を組むときだけ呼ぶ
    /// (sut-ec-mobile: 保存の tap が空振り → 戻る → 次の tap が「解決できない」で、空振りした保存を名指しできなかった)
    func unresolvedActionTapHint(_ elements: [ElementInfo]) -> String {
        var taps = stillUnchangedEarlierTaps(tapEvidenceAtEntry.earlier, at: elements)
        if let pending = tapEvidenceAtEntry.pending, Self.sameContent(pending.before, elements) {
            taps.append(pending.description)
        }
        guard !taps.isEmpty else { return "" }
        noteCodesThisStep.insert(.unchangedTapBeforeFailure)
        // 比べた相手は次のタップとは限らない(この手は type 等でありうる)= 「次の手」と言う
        return earlierTapsHint(Array(taps.suffix(Self.unchangedEarlierTapsLimit)), also: false, nextAction: "the step")
    }

    /// iOS の木はアプリのプロセスだけ(in-app / XCUITest とも)。SpringBoard のアラート(権限の要求等)を
    /// 出したタップも木では「無変化」に見えるので、飲まれたと言い切らない(M1mini の E2E-iOS 16 S0010:
    /// 写真の権限アラートが 5 秒以内に出なかった赤に、この注記が「飲まれた」と誤誘導した)。
    /// Android は権限ダイアログがアクティブウィンドウとして木に載るので足さない
    private var outOfAppCaveat: String {
        isAndroid ? "" : ", or it raised a system alert (e.g. a permission request), which is drawn outside"
            + " the app and never appears in its tree"
    }

    /// **失敗したステップの対象が直前の tap の対象と違っても黙らない**: tap の結果を別の要素(選択の表示等)で確かめて落ちる場面が、
    /// この注記がいちばん役に立つ所(SwallowedInteractionTests.testFailureReportsHowFarTheTargetMovedAfterTheTap)。文言は事実だけ(OI-184 ②)
    private func lastTapHint(_ elements: [ElementInfo]?) -> (text: String, unchanged: Bool) {
        guard let last = lastInteraction, let elements, !elements.isEmpty else { return ("", false) }
        if Self.contentSignature(elements) == Self.contentSignature(last.before) {
            var text = " (the preceding \(last.description) did not change the screen at all"
                + "; the interaction may have been swallowed\(outOfAppCaveat)"
            if let taken = last.pointTakenBy {
                // 名指しであって貼れるセレクタの保証はしない(TapTargetGeometry.describe と同じ判断。
                // エスケープ未対応)
                let label = taken.identifier.map { "#\($0)" } ?? taken.label.map { "\"\($0)\"" }
                    ?? taken.type
                text += " — its point was inside \(label), which is in front of the target"
            } else if last.pointTakenSuppressed {
                noteCodesThisStep.insert(.occluderNamingSuppressed)
            }
            return (text + ")", true)
        }
        guard let now = Self.relocate(last.target, in: elements) else { return ("", false) }
        let dx = now.frame.x - last.target.frame.x
        let dy = now.frame.y - last.target.frame.y
        guard (dx * dx + dy * dy).squareRoot() >= Self.movedTargetThreshold else { return ("", false) }
        // 「動く前の座標を撃った」とは言わない: tap は ref で撃たれ、ブリッジが撃つ時点の枠の中心へ解決する。動いたのは tap の結果
        // (焦点 → キーボードで押し上げ等)のことが多く、失敗したステップが tap と無関係でも同じ文が付いていた
        // 動いたのは直前の tap の対象(失敗したステップの対象とは限らない)= 主語を「the target」にしない(探索 11/27 amax F1)
        return (" (the element that \(last.description) hit has moved (\(Int(saturating: dx)),\(Int(saturating: dy))) since that tap"
            + " — the layout shifted after that tap (for example the keyboard opened and pushed the content up)."
            + " This is only a fact about the screen: the tap itself may have been fine)", false)
    }

    /// 「動いた」と言い切る下限(pt)。整定のわずかな揺れやサブピクセルで注記を出さないための床。
    /// 実測の取りこぼしは 98pt 級(docs/verification/ の計装記録)なので、この値で十分拾える
    static let movedTargetThreshold: Double = 8

    /// タップした要素を**別の木の中で**探し直す。id があれば id、無ければ型+ラベル。
    /// 見つからなければ nil = 黙る(消えた要素について「動いた」とは言えない)
    static func relocate(_ target: ElementInfo, in elements: [ElementInfo]) -> ElementInfo? {
        if let id = target.identifier, !id.isEmpty {
            return elements.first { $0.identifier == id }
        }
        guard let label = target.label, !label.isEmpty else { return nil }
        return elements.first { $0.type == target.type && $0.label == label }
    }
}
