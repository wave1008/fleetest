import Foundation

extension StepExecutor {

    /// 撃つ前に対象へ届かせた結果
    enum PreTouch {
        /// 撃ってよい。**element / snapshot は撮り直した後のもの**(撃つ前の ref は無効)
        case proceed(element: ElementInfo, snapshot: SnapshotResponse, note: String?)
        case refused(String, kind: StepFailureKind?)
    }

    /// 撃つ前の入口の使い方
    enum EntrancePlan: Equatable {
        /// 通さない(tap の押すだけの形は自前の経路 / 要素を触らない操作 / 大きな面への swipeBy)
        case skip
        case full
        /// 容器を送って覆いを外す段(`liftCoveredTarget`)を除く。大きな面へのピンチ・ジェスチャは対象そのものが容器で、送ると
        /// 操作の対象が動く
        case withoutLift
    }

    /// 大きな面か: スクロールの容器と申告した・高さが画面の半分以上。**キーボードの下まで伸びるのが通常**で、中心が下でも
    /// swipeBy の払いは画面の中で切られる = 閉じて撃つ・断る対象にしない(緑を赤にしない)
    static func isSurfaceTarget(_ element: ElementInfo, screen: FTRect) -> Bool {
        element.scrollable == true || (screen.height > 0 && element.frame.height >= screen.height / 2)
    }

    /// この手が撃つ前の入口(`reachBeforeTouch`)を通るか。分類は `StepAction.touchClass`(手書きの集合を持たない)。
    /// tap の押すだけの形は自前の経路(lift → 閉じる → 撃つ)で同じ部品を通るので含めない。tap の hold > 0 は通す
    static func entrancePlan(action: String, step: FlowStep, element: ElementInfo, screen: FTRect) -> EntrancePlan {
        guard let known = StepAction(rawValue: action) else { return .skip }
        switch known.touchClass {
        case .noElementTouch: return .skip
        case .ownGuardedPath:
            return known == .tap && (step.duration ?? FlowStep.defaultTapHoldSeconds) > 0 ? .full : .skip
        case .touchesElement:
            guard isSurfaceTarget(element, screen: screen) else { return .full }
            switch known {
            case .swipeBy: return .skip
            case .pinchOut, .pinchIn, .gesture: return .withoutLift
            case .doubleTap, .holdStart, .swipeElementToElement: return .full
            case .tap, .type, .clearInput, .findImage, .findImages, .existImage, .swipe, .scroll, .scrollToEdge,
                 .flick, .scrollTo, .swipePointToPoint, .fold, .unfold, .hinge, .rotateTo, .pressEnter,
                 .hideKeyboard, .holdEnd, .waitForSettle, .select:
                return .full
            }
        }
    }

    /// **要素を指で触る操作の撃つ前の入口**: 容器の縁の帯に潜っていれば送って外す → キーボードで潰れた・せり上がったバーに
    /// 覆われた対象はキーボードを閉じて引き直す → なお中心がキーボードの下なら閉じてから届かせる(閉じられなければ断る)。
    /// tap と type が使う部品(`liftCoveredTarget` / `closeKeyboardWithoutSideEffects` / `reachPastKeyboard`)をそのまま通す。
    /// 覆いの判定は `PreFireGuard` + `OcclusionGeometry` の1つ。**木の並びで手前が読めない覆い**(Flutter の貼り付く見出し)は
    /// `pinnedBandCovering` の帯の推定の範囲でだけ送る(推定の外は注記に止める = 誤って断らない)
    func reachBeforeTouch(_ element: ElementInfo, in snapshot: SnapshotResponse, step: FlowStep, action: String,
                          snapshotSource: CoverLiftSnapshotSource, liftsTarget: Bool,
                          phase: inout PhaseAccumulator) async throws -> PreTouch {
        var element = element
        var snapshot = snapshot
        var notes: [String?] = []
        if liftsTarget,
           let lifted = try await liftCoveredTarget(element, in: snapshot, step: step, verb: "touching",
                                                    snapshotSource: snapshotSource, phase: &phase) {
            guard let liftedElement = lifted.element else {
                return .refused(Self.coverLiftLostMessage(step, verb: "touching", after: lifted.snapshot)
                    + (await leftForegroundSuffix(snapshot.sessionBundleID)), kind: .notFound)
            }
            element = liftedElement
            snapshot = lifted.snapshot
            notes.append(lifted.note)
        }
        let keyboard = KeyboardOcclusion.resolve(reported: snapshot.keyboardFrame, in: snapshot.elements,
                                                 screen: snapshot.screen)
        if case .primary = snapshotSource,
           PreFireGuard.keyboardCover(of: element, in: snapshot, keyboard: keyboard) != nil,
           case .closed(let closedNote, _) = try await closeKeyboardWithoutSideEffects(step: step, phase: &phase) {
            let start = ContinuousClock().now
            let after = try await freshSnapshot(.afterOwnMove)
            phase.snapshotMs += Self.ms(ContinuousClock().now - start)
            // 引けなければ撃たない(閉じる前の要素は前の木の ref と枠 = 撃つと別の物に当たる。寄せの後と同じ)
            guard let (reached, _) = LocatorResolver.resolve(step: step, in: after) else {
                return .refused(Self.keyboardClosedLostMessage(step, closedNote: closedNote)
                    + (await leftForegroundSuffix(snapshot.sessionBundleID)), kind: .notFound)
            }
            snapshot = after
            element = reached
            notes.append(closedNote + " — the target was collapsed or covered by a bar raised above the keyboard while it was up")
        }
        switch try await reachPastKeyboard(element, in: snapshot, step: step, action: "tap",
                                           snapshotSource: snapshotSource, phase: &phase) {
        case nil: break
        case .refused(let message)?: return .refused(message, kind: nil)
        case .reached(let reached, let after, let note)?:
            element = reached
            snapshot = after
            notes.append(note)
        }
        return .proceed(element: element, snapshot: snapshot,
                        note: notes.compactMap { $0 }.isEmpty ? nil : notes.compactMap { $0 }.joined(separator: " / "))
    }

    /// **frame の中心を撃つ指の操作で、中心が画面の外なら撃たずに断る文**(長押し・doubleTap・要素から要素へのドラッグの始点と終点・
    /// Android のピンチ)。ウィンドウ外のタッチは黙って落ちるので撃っても何も起きず ok になる。
    /// 判定は `TapTargetGeometry.offscreenScrollGateCentre`(MCP・スクロール探索の「見つかった」ゲートと共有。画面より大きい軸は免除)。
    /// **tap の押すだけの形は対象外**(`visibleTapRect` で見えている部分へ寄せる経路があり、助言に止めている)。
    /// iOS のピンチは XCUITest が identifier の要素へ撃つので対象外(中心の外を撃つとは限らない)。文言は呼び手ごと
    static func offscreenCentreRefusal(action: String, step: FlowStep, element: ElementInfo,
                                       screen: FTRect, isAndroid: Bool, role: String? = nil) -> String? {
        let fires: Bool
        switch action {
        case "doubleTap", "swipeElementToElement": fires = true
        case "tap": fires = (step.duration ?? FlowStep.defaultTapHoldSeconds) > 0
        case "pinchOut", "pinchIn": fires = isAndroid
        default: fires = false
        }
        guard fires, let c = TapTargetGeometry.offscreenScrollGateCentre(for: element, screen: screen) else { return nil }
        return "cannot \(action): the \(role ?? "target")'s centre (\(Int(c.x)), \(Int(c.y))) is outside the visible screen"
            + " (\(Int(screen.width))x\(Int(screen.height))), so the touch would land nowhere and nothing was sent."
            + " Bring it into view first (scroll: / scrollTo)"
    }
}
