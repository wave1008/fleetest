import Foundation

// inapp-boost の肯定の存在のアサーションが見つからずに締め切りへ来たとき、赤にする前にアプリ自身の XCUITest の木を1回照会する(DR-199)
extension StepExecutor {
    /// 見えていると確かめられなかったときに立つ注記(XCUITest の木で見つかっても採らない)
    static let unverifiedVisibilityNotes: Set<StepNote> = [
        .visualTextCheckUnsupported, .visibilityGuardSkipped, .blankScreenshot, .webViewCaptureBlank,
    ]

    /// 見つかって、テキストの可視性検証を通り、読めたときだけ要素を返す。in-app の木からアプリの中の材料で読めない描き方
    /// (iOS 27.2 の連絡先の空状態の文字は UIView にも読み上げ用の要素にも無く、OS の読み上げの仕組みにだけ出る)を拾う。
    /// **XCUITest の木はモーダルの裏の要素も残す**ので、見つかっただけで採らない = 可視性検証が無効・読めなかった回は採らない
    func appXCUITestTreeMatch(step: FlowStep, phase: inout PhaseAccumulator) async throws -> ElementInfo? {
        // 可視性検証が無効なら下の「文字を読めた」でも落ちる。ここは XCUITest の木を読む手間を省くだけ
        guard !isAndroid, let xcuitest = typeDriver, let bundleID = launchedBundleID,
              visibilityGuardActive(perStepGuard: step.occlusionGuard) else { return nil }
        // XCUITest の snapshot は対象を activate する = 前面を離れたアプリを引き戻すので、activate しない /appstate で前面を確かめてから読む
        let foreground: Bool
        do { foreground = try await xcuitest.isAppForeground(bundleID: bundleID) } catch {
            noteCodesThisStep.insert(.xcuitestTreeUnread)
            return nil
        }
        guard foreground else { return nil }
        let clock = ContinuousClock()
        let start = clock.now
        guard let tree = try? await xcuitest.snapshot() else {
            noteCodesThisStep.insert(.xcuitestTreeUnread)
            return nil
        }
        phase.snapshotMs += Self.ms(clock.now - start)
        guard let (element, _) = LocatorResolver.resolve(step: step, in: tree, strictForAssert: true) else { return nil }
        let notesBefore = noteCodesThisStep
        let pixelsBefore = pixelsShowedTextThisStep
        pixelsShowedTextThisStep = false
        defer { pixelsShowedTextThisStep = pixelsShowedTextThisStep || pixelsBefore }
        let flip = try await occlusionFlip(
            element: element, expectedText: element.label ?? step.locator?.label ?? "",
            elements: tree.elements, screen: tree.screen,
            keyboardShown: KeyboardWait.isShown(tree), keyboard: tree.keyboardFrame,
            looseMatch: false, perStepGuard: step.occlusionGuard, phase: &phase)
        // 素通りの段(対象外の型・段が未設定・絵が古い 等)は文字を読まずに nil を返すので、画素に文字を読めた回だけ採る
        guard flip == nil, pixelsShowedTextThisStep, noteCodesThisStep.subtracting(notesBefore).isDisjoint(with: Self.unverifiedVisibilityNotes) else {
            return nil
        }
        return element
    }

    /// 操作(tap・type 等)の対象が in-app の木で解けなかったとき、キーボードを閉じる・赤にする前にアプリの XCUITest の木を1回照会する。
    /// 見つかって **XCUITest が押せる(`isHittable`)と答えた**ときだけ、その木とドライバで撃つ(XCUITest の木はモーダルの裏の要素も残す =
    /// 見つかっただけでは採らない。押せるかの判定はデバイスの答えに任せる)。標準アプリのリマインダーの新規行の入力欄は in-app の木に
    /// 出ず、XCUITest の木にだけ出た(OI-290 ①)。前面の確かめは `appXCUITestTreeMatch` と同じ(XCUITest の木の読みは activate する)
    func appXCUITestTreeActionTarget(step: FlowStep, action: String,
                                     phase: inout PhaseAccumulator) async -> (element: ElementInfo, usedFallback: FlowLocator?,
                                                                             snapshot: SnapshotResponse, driver: AppDriver)? {
        guard !isAndroid, let xcuitest = typeDriver, let bundleID = launchedBundleID,
              PreFireGuard.keyboardSensitiveActions.contains(action) else { return nil }
        let foreground: Bool
        do { foreground = try await xcuitest.isAppForeground(bundleID: bundleID) } catch {
            noteCodesThisStep.insert(.xcuitestTreeUnread)
            return nil
        }
        guard foreground else { return nil }
        let clock = ContinuousClock()
        let start = clock.now
        guard let tree = try? await xcuitest.snapshot() else {
            noteCodesThisStep.insert(.xcuitestTreeUnread)
            return nil
        }
        phase.snapshotMs += Self.ms(clock.now - start)
        guard let (element, usedFallback) = LocatorResolver.resolve(step: step, in: tree),
              (try? await xcuitest.hitTest(ref: element.ref)) == .hittable(true) else { return nil }
        noteCodesThisStep.insert(.actedViaXCUITestTree)
        return (element, usedFallback, tree, xcuitest)
    }
}
