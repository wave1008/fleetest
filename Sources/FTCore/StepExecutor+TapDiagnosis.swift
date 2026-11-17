// StepExecutor+TapDiagnosis.swift
// 失敗したステップに付ける、直前の tap の診断(飲まれた・対象が動いた・覆われた)と探す範囲の案内の文言。
// 本体は StepExecutor.swift(instance 状態はそちらに置く)

import Foundation

extension StepExecutor {
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
            text += "|\(Int(frame.x)),\(Int(frame.y)),\(Int(frame.width)),\(Int(frame.height));"
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
        if last.unchanged || !unchangedEarlierTaps.isEmpty {
            noteCodesThisStep.insert(.unchangedTapBeforeFailure)
        }
        return last.text + coveredTouchHint() + earlierTapsHint()
    }

    /// 直前の触る操作が覆いの重なった疑いのまま撃たれていたら、それを名指して直し方を言う(失敗のときだけ呼ばれる)。
    /// **原因と断定しない**(「それが原因なら」)。重なりは画面の大きさで変わるので、直すのは出たデバイスを見た利用者
    func coveredTouchHint() -> String {
        guard let last = lastInteraction, let cover = last.coverSuspect else { return "" }
        noteCodesThisStep.insert(.coveredTouchBeforeFailure)
        return " (when the preceding \(last.description) was fired, \(cover) overlapped the target's centre on this device,"
            + " so the touch may have landed on \(cover) instead — if that is why this step failed, fix the scenario so the"
            + " target is not covered at that step. \(Self.uncoverRemedy(cover: cover, step: nil)))"
    }

    /// 次のタップの時点で画面が変わっていなかった、それより前のタップ(`unchangedEarlierTaps`)。
    /// 直前のタップの結果とは独立に添える —— 直前のタップが「画面を変えないのが正常」な操作でも、
    /// その前のタップが効いていなかった事実は消さない
    private func earlierTapsHint(_ taps: [String]? = nil, also: Bool = true, nextAction: String = "the tap") -> String {
        let taps = taps ?? unchangedEarlierTaps
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
            reason = " — it is a \(container.type), which holds no other elements"
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
        var taps = tapEvidenceAtEntry.earlier
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
            }
            return (text + ")", true)
        }
        guard let now = Self.relocate(last.target, in: elements) else { return ("", false) }
        let dx = now.frame.x - last.target.frame.x
        let dy = now.frame.y - last.target.frame.y
        guard (dx * dx + dy * dy).squareRoot() >= Self.movedTargetThreshold else { return ("", false) }
        // 「動く前の座標を撃った」とは言わない: tap は ref で撃たれ、ブリッジが撃つ時点の枠の中心へ解決する。動いたのは tap の結果
        // (焦点 → キーボードで押し上げ等)のことが多く、失敗したステップが tap と無関係でも同じ文が付いていた
        return (" (the target has moved (\(Int(dx)),\(Int(dy))) since the preceding"
            + " \(last.description) — the layout shifted after that tap (for example the keyboard opened and pushed the content up)."
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
