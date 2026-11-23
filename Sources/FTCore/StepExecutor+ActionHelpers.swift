// StepExecutor+ActionHelpers.swift
// executeAction が使う補助(ジェスチャの合成・失敗文言・drag/doubleTap/pinch/gesture のフォールバック)。
// 本体は StepExecutor+Actions.swift

import Foundation

extension StepExecutor {

    /// **横スクロールの残骸を掴んでいないか**(判定は `DuplicateRegion` = MCP の
    /// `duplicateRegionNote` と共有)。**座標に依らない**ので keyboard/disabled と同じく
    /// 掴んだ時点で確定してよい —— 言っているのは「この ref はもう描かれていないコピーかも
    /// しれない」であって、撃つ点をどこへ寄せるかとは無関係。
    ///
    /// **注記だけで拒否しない**: どちらのコピーが生きているかは木から決められないので、
    /// 撃たずに止めると正しい操作まで殺す。
    /// **tap と doubleTap の両方から呼ぶ**(どちらも指で触る操作。片方だけ黙ると判断が食い違う)
    func duplicateRegionAdvisory(_ element: ElementInfo, in snapshot: SnapshotResponse) -> String? {
        guard let duplicate = DuplicateRegion.riskFor(element, in: snapshot.elements) else {
            return nil
        }
        noteCodesThisStep.insert(.staleDuplicateRegion)
        return "the tree lists this row twice ([\(duplicate.firstRef)] and"
            + " [\(duplicate.secondRef)], \(duplicate.length) elements each);"
            + " one copy is a leftover from horizontal scrolling"
    }

    /// 注記の合流(どちらか片方だけのことが多いので nil を潰して " / " で繋ぐ)
    static func joinNotes(_ notes: String?...) -> String? {
        let present = notes.compactMap { $0 }.filter { !$0.isEmpty }
        return present.isEmpty ? nil : present.joined(separator: " / ")
    }

    /// 対象を取り得るジェスチャ(対象未指定なら画面全体)。ロケータ有無で解決だけが違うので
    /// 実体はここ1箇所に置く
    static let gestureActions: Set<String> = ["pinchOut", "pinchIn", "doubleTap", "swipeBy", "gesture"]

    /// ピンチ / ダブルタップ / 相対ドラッグの実行。target = 対象領域(要素の frame か画面)、
    /// viewport = 画面矩形。**慣性が乗るので末尾で必ず整定を待つ**(ランナーはこれらのルートを
    /// 整定対象に入れていない。理由は BridgeRouter.mutatingPaths のコメント)
    ///
    /// **private ではない**: StepExecutor+DirectActions.swift の executeDirectUntargetedGesture からも呼ぶ
    func performGesture(_ action: String, step: FlowStep, target: FTRect,
                        identifier: String?, viewport: FTRect,
                        phase: inout PhaseAccumulator) async throws -> StepOutcome {
        var viaXCUITest = false
        var bandNote: String?
        switch action {
        case "pinchOut", "pinchIn":
            let out = action == "pinchOut"
            let scale = step.scale
                ?? (out ? FlowStep.defaultPinchOutScale : FlowStep.defaultPinchInScale)
            // **向きと倍率が食い違ったら実行しない**。撃ってしまうと「pinchOut と書いたのに
            // 縮小された」が成功として記録され、書き間違いに気付けない
            guard scale.isFinite, out ? scale > 1 : (scale > 0 && scale < 1) else {
                return StepOutcome(status: .failed(
                    out ? "pinchOut requires scale > 1 (got \(scale)). Use pinchIn to zoom out."
                        : "pinchIn requires 0 < scale < 1 (got \(scale)). Use pinchOut to zoom in."))
            }
            viaXCUITest = try await pinchWithFallback(
                frame: target, identifier: identifier, scale: scale,
                durationSeconds: step.duration ?? tunables.defaultPinchDuration,
                phase: &phase)
        case "doubleTap":
            let bandY = await bottomBandTapY(for: target, screen: viewport)
            viaXCUITest = try await doubleTapWithFallback(x: target.centerX, y: bandY ?? target.centerY,
                                                          phase: &phase)
            if bandY != nil { bandNote = Self.bottomBandTapNote }
        case "swipeBy":
            // iOS/3ボタン navigation は nil → 除外なし(0, 0)。既定値を panPath 側に置かないのは
            // この分岐に確実に決めさせるため(ScrollGeometry.panPath の doc 参照)
            let readWidths = await driver.backGestureEdgeWidths()
            let backGestureEdgeWidths = readWidths ?? (left: 0, right: 0, bottom: 0)
            // **Android で帯を読めなかった事実は言う**: 除かずに払うので、端まで届く払いの始点・終点が帯に乗ると OS の
            // 「戻る」として消費される(E2EX-CMP android 不具合の回帰 S0050 で1回: dx -0.9 の始点は帯を読めないと x 1026 =
            // 右の帯 1002〜 の中、読めていれば 956)。原因の帰属はこの注記が出た回だけできる
            // 読めなかった理由(期限切れ・終了コード・出力の欠け)も足す = どちらで読めないのかを測る
            if isAndroid, readWidths == nil {
                bandNote = Self.backGestureBandUnreadNote
                    + (driver.backGestureBandReadFailure().map { " (why: \($0))" } ?? "")
            }
            guard let path = ScrollGeometry.panPath(container: target, viewport: viewport,
                                                    dxRatio: step.dxRatio ?? 0,
                                                    dyRatio: step.dyRatio ?? 0,
                                                    backGestureEdgeWidths: backGestureEdgeWidths) else {
                // 動かないドラッグを撃って「成功」と記録すると、比率の書き間違いに気付けない
                return StepOutcome(status: .failed(
                    "swipeBy cannot build a usable path (the target area is off-screen, "
                        + "or dxRatio/dyRatio are too small to move a finger)"))
            }
            viaXCUITest = try await dragWithFallback(
                path: path,
                durationSeconds: step.duration ?? tunables.defaultSwipeDuration,
                phase: &phase)
        case "gesture":
            // 検査は写す前(比率)の段で言う(TouchGesture.resolve の doc)。失敗はデバイスに触らず返す
            // —— 以降の共通処理(末尾の整定待ち)は実際に撃った回だけ通したいので、ここで早期 return する
            switch TouchGesture.resolve(step.gesture ?? [], in: target, screen: viewport,
                                        maxGestureSeconds: step.maxGestureSeconds
                                            ?? BridgeAPI.defaultMaxGestureSeconds) {
            case .failure(let rejection):
                return StepOutcome(status: .failed(rejection.message))
            case .success(let request):
                viaXCUITest = try await gestureWithFallback(phase: &phase) {
                    try await $0.gesture(request)
                }
            }
        default:
            return StepOutcome(status: failedWithoutKind(Self.unknownStepMessage(kind: "gesture", name: action)))
        }
        let settled = skippingSettle(step) ? true : try await settledSignature(phase: &phase).settled
        var notes: [String] = []
        if viaXCUITest { notes.append("fell back to XCUITest") }
        if let bandNote { notes.append(bandNote) }
        if !settled { note(.settleCapped, into: &notes) }
        // 比率は対象の大きさに対する割合で片側 maxPanRatio が上限。超えた指定を黙って丸めると、小さい要素で
        // 「14 倍払った」つもりが数 pt しか動かず緑になる(実測: シートの見出しで閉じなかった)
        if action == "swipeBy",
           [step.dxRatio, step.dyRatio].contains(where: { abs($0 ?? 0) > ScrollGeometry.maxPanRatio }) {
            note(.swipeByRatioCapped, into: &notes)
        }
        return StepOutcome(status: .passed,
                           driverFallback: notes.isEmpty ? nil : notes.joined(separator: " / "))
    }

    /// 消去の後の木で、消した欄と**同じ欄**を引き直す(nil = 撃たない)。判定は MCP と共有(`ClearedFieldRelocation.relocate`)
    static func relocateAfterClear(_ element: ElementInfo, step: FlowStep, in snapshot: SnapshotResponse) -> ElementInfo? {
        ClearedFieldRelocation.relocate(element, in: snapshot.elements,
                                        locate: { LocatorResolver.resolve(step: step, in: snapshot)?.0 })
    }

    static func clearLostTargetMessage(_ step: FlowStep) -> String {
        "the field was cleared for replace:, but it could not be found on the screen afterwards:"
            + " \(step.locatorSummary) (nothing was typed)"
    }

    static func allMatchesCoveredMessage(_ step: FlowStep, count: Int, over: ElementInfo) -> String {
        "did not touch \(step.locatorSummary): it matched \(count) elements and the centre of every one is covered by another element"
            + " (the first by \(TapTargetGeometry.describe(over))), so touching any of them would hit what covers it (nothing was touched)"
    }

    /// 送った後に対象を見失ったときの失敗文(撃つ前の ref で撃たない理由を言う)
    ///
    /// **送った後の木がロック画面・常時表示(消灯)なら「覆われた」と言わない** —— 端末の画面が落ちた(か施錠された)事実を言う。
    /// 覆いの経路の文を出すと、画面が消えただけなのにアプリの UI が対象を覆ったように読める。送った分のスクロールが
    /// アプリに届いたかも言えない。木は送った後に読んだものを使う(追加の読みは無い)
    static func uncoveredAlternativeNote(_ element: ElementInfo) -> String {
        "the first match is covered by another element, so the uncovered match "
            + (element.identifier.map { "#\($0)" } ?? "at (\(Int(saturating: element.frame.centerX)), \(Int(saturating: element.frame.centerY)))")
            + " was touched instead"
    }

    static func nudgeLostMessage(_ step: FlowStep) -> String {
        "the target straddled its container's edge, so a slow drag was sent to bring it inside before touching it,"
            + " but the target could not be found on the screen afterwards: \(step.locatorSummary) (nothing was touched)"
    }

    /// キーボードが出たまま・閉じられずに、ScrollView の中の対象へ撃った(`PreFireGuard.tapOnlyDismissesKeyboard`)ときの注記。
    /// 事実だけ: 閉じようとして閉じられなかった・React Native の既定ではその最初のタップが閉じるだけになりうる。押されたかは言わない
    static func keyboardStayedUpNote(_ why: String) -> String {
        "the keyboard was up and could not be closed before the tap (\(why)); inside a React Native scroll view the first tap"
            + " may only dismiss the keyboard, so the target may not have been pressed — check the result, or close the keyboard first"
    }

    static func keyboardClosedLostMessage(_ step: FlowStep, closedNote: String) -> String {
        "the soft keyboard was covering the target, so it was closed before touching it (\(closedNote)), but the target"
            + " could not be found on the screen afterwards: \(step.locatorSummary) (nothing was touched)"
    }

    /// in-app ブリッジが type / clearInput / pressEnter を 409 で断ったときの DSL 向けの失敗文。ブリッジの文言は ref を渡す前提の案内を含むので載せない。
    /// 言うのは事実だけ: 断られた・XCUITest での撃ち直しを試みたか。**断った理由を推測で言わない**(焦点が欄に立っていても 409 は返る)
    /// Android に in-app / XCUITest ブリッジは無いので、その語は iOS だけ(`focusedFieldRefusal` と同じ分け方)
    static func inputFocusMissMessage(_ step: FlowStep, verb: String, tried: Bool, isAndroid: Bool) -> String {
        if isAndroid { return "the Android bridge refused to \(verb) \(step.locatorSummary) (HTTP 409)" }
        return "the in-app bridge refused to \(verb) \(step.locatorSummary) (HTTP 409)"
            + (tried ? ", and the XCUITest bridge could not find the field in its own tree either"
                     : ", and no XCUITest bridge is available to retry")
    }

    static func typeFocusMissMessage(_ step: FlowStep, tried: Bool, isAndroid: Bool) -> String {
        inputFocusMissMessage(step, verb: "type into", tried: tried, isAndroid: isAndroid)
    }

    /// `slowDrag` に渡す枠: 容器のうち画面に出ていてキーボードに覆われていない部分(slowDrag は渡した枠を始点・終点の両方に使う)。
    /// キーボードは実効矩形(`KeyboardOcclusion.resolve` = 画面の外に申告された隠れたキーボードを捨てる)を画面から除き、容器と交わらせる
    /// (探索のループと同じ順。`ScrollGeometry.viewport` は画面を受け取る前提)。交わらなければ nil = 撃たない
    static func visibleDragArea(_ container: FTRect, in snapshot: SnapshotResponse) -> FTRect? {
        let keyboard = KeyboardOcclusion.resolve(reported: snapshot.keyboardFrame, in: snapshot.elements,
                                                 screen: snapshot.screen).frame
        return ScrollGeometry.intersection(container, ScrollGeometry.viewport(snapshot.screen, excludingKeyboard: keyboard))
    }

    static func coverLiftLostMessage(_ step: FlowStep, verb: String, after: SnapshotResponse? = nil) -> String {
        let done = verb == "typing" ? "typed" : verb == "clearing" ? "cleared" : "touched"
        if let after, SystemUITreeKind.isLockScreenOrAlwaysOn(
            sessionBundleID: after.sessionBundleID, identifiers: after.elements.map(\.identifier)) {
            return "the target could not be found on the screen: \(step.locatorSummary) — the lock screen / always-on display is in front"
                + " (the device screen went dark or is locked), so the app is not being shown; the container scroll sent before \(verb)"
                + " it may not have reached the app (nothing was \(done))"
        }
        return "the target was covered, so the container was scrolled before \(verb) it, but the target could not be"
            + " found on the screen afterwards: \(step.locatorSummary) (nothing was \(verb == "typing" ? "typed" : verb == "clearing" ? "cleared" : "touched"))"
    }

    /// 座標ドラッグを通常ドライバ →(501/ルート不明404 なら)typeDriver の順で撃つ。
    /// 座標はブリッジ間で共通(ref と違い取り直しが要らない)ので、そのまま渡すだけでよい。
    /// 戻り値: true = typeDriver(XCUITest)経由
    /// **private ではない**: StepExecutor+DirectActions.swift の executeDirectFlick からも呼ぶ
    func dragWithFallback(path: FTSwipePath, durationSeconds: Double,
                          phase: inout PhaseAccumulator) async throws -> Bool {
        try await gestureWithFallback(phase: &phase) {
            try await $0.drag(fromX: path.fromX, fromY: path.fromY,
                              toX: path.toX, toY: path.toY,
                              pressSeconds: FlowStep.defaultDragPressSeconds, durationSeconds: durationSeconds)
        }
    }

    private func doubleTapWithFallback(x: Double, y: Double,
                                       phase: inout PhaseAccumulator) async throws -> Bool {
        try await gestureWithFallback(phase: &phase) { try await $0.doubleTap(x: x, y: y) }
    }

    private func pinchWithFallback(frame: FTRect, identifier: String?, scale: Double,
                                   durationSeconds: Double,
                                   phase: inout PhaseAccumulator) async throws -> Bool {
        try await gestureWithFallback(phase: &phase) {
            try await $0.pinch(frame: frame, identifier: identifier, scale: scale,
                               durationSeconds: durationSeconds)
        }
    }

    /// 座標だけで完結するジェスチャの共通フォールバック。in-app が「このブリッジでは不可」と
    /// 返したとき(501 / ルート不明 404)だけ XCUITest へ回す —— in-app は自前描画の
    /// フレームワークなら多点も撃てるが、UIKit/SwiftUI では合成タッチが受理されず 501 を返す。
    /// **409 は含めない**(理由は DriverError.isBridgeIncapable)。
    /// **private ではない**: StepExecutor+Hold.swift の executeHoldStart からも呼ぶ
    func gestureWithFallback(phase: inout PhaseAccumulator,
                             _ body: (AppDriver) async throws -> Void) async throws -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        // 届いた印(`gestureDeliveredThisStep`)を立てる: 立てないと、届いた後の読みの失敗が「届いていない」と記録され、
        // 撃ち直してよい側に数えられる(DR-136)。swipeWithFallback / 座標の dragWithFallback と同じ
        do {
            try await body(driver)
            gestureDeliveredThisStep = true
            phase.actionMs += Self.ms(clock.now - start)
            return false
        } catch {
            guard DriverError.isBridgeIncapable(error), let td = typeDriver else { throw error }
            try await body(td)
            gestureDeliveredThisStep = true
            phase.actionMs += Self.ms(clock.now - start)
            return true
        }
    }
}
