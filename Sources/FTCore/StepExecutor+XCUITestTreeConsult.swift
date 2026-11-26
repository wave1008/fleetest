import Foundation

// inapp-boost の肯定の存在のアサーション・テキスト比較が見つからずに締め切りへ来たとき、赤にする前にアプリ自身の XCUITest の木を1回照会する(DR-199)
extension StepExecutor {
    /// 見えていると確かめられなかったときに立つ注記(XCUITest の木で見つかっても採らない)
    static let unverifiedVisibilityNotes: Set<StepNote> = [
        .visualTextCheckUnsupported, .visibilityGuardSkipped, .blankScreenshot, .webViewCaptureBlank,
    ]

    /// 見つかって、テキストの可視性検証を通り、読めたときだけ要素を返す。in-app の木からアプリの中の材料で読めない描き方
    /// (iOS 27.2 の連絡先の空状態の文字は UIView にも読み上げ用の要素にも無く、OS の読み上げの仕組みにだけ出る)を拾う。
    /// **XCUITest の木はモーダルの裏の要素も残す**ので、見つかっただけで採らない = 可視性検証が無効・読めなかった回は採らない
    /// `matchedText`: テキスト比較(textIs 等)から呼ぶときの「その要素の値が期待に合えば、画面で確かめる文字」。nil を返す要素は
    /// 期待に合わない = 採らない(`xcuitestTreeNoMatch`)。存在のアサーションは渡さない(ラベルで確かめる)
    func appXCUITestTreeMatch(step: FlowStep, phase: inout PhaseAccumulator,
                              matchedText: ((ElementInfo, SnapshotResponse) -> String?)? = nil) async throws -> ElementInfo? {
        // 可視性検証が無効なら下の「文字を読めた」でも落ちる。ここは XCUITest の木を読む手間を省くだけ
        guard !isAndroid, let xcuitest = typeDriver, let bundleID = launchedBundleID else { return nil }
        guard visibilityGuardActive(perStepGuard: step.occlusionGuard) else {
            noteCodesThisStep.insert(.xcuitestTreeNotConsulted)
            return nil
        }
        guard let tree = await readAppXCUITestTree(xcuitest: xcuitest, bundleID: bundleID, phase: &phase) else { return nil }
        guard let (element, _) = LocatorResolver.resolve(step: step, in: tree, strictForAssert: true) else {
            noteCodesThisStep.insert(.xcuitestTreeNoMatch)
            return nil
        }
        let textToVerify: String
        if let matchedText {
            guard let text = matchedText(element, tree) else {
                noteCodesThisStep.insert(.xcuitestTreeNoMatch)
                return nil
            }
            textToVerify = text
        } else {
            textToVerify = element.label ?? step.locator?.label ?? ""
        }
        let notesBefore = noteCodesThisStep
        let pixelsBefore = pixelsShowedTextThisStep
        pixelsShowedTextThisStep = false
        defer { pixelsShowedTextThisStep = pixelsShowedTextThisStep || pixelsBefore }
        let flip = try await occlusionFlip(
            element: element, expectedText: textToVerify,
            elements: tree.elements, screen: tree.screen,
            keyboardShown: KeyboardWait.isShown(tree), keyboard: tree.keyboardFrame,
            looseMatch: false, perStepGuard: step.occlusionGuard, app: tree.sessionBundleID, phase: &phase)
        // 素通りの段(対象外の型・段が未設定・絵が古い 等)は文字を読まずに nil を返すので、画素に文字を読めた回だけ採る
        // 検証が素通りの段(対象外の型)で降りて画素を読まなかった行は、その枠を OCR で1回読む。XCUITest の木の行は
        // 入力欄の子(標準アプリのリマインダーの題名 = `textField "タイトル"`)を持つので行の確かめ(V4)に乗らず、見えていても採れなかった。
        // 結合ラベル(「題名、未実行」)は先頭の区切りで比べる(読み上げ用の文は描かれない = OCROnlyVisibility.rowLabelNotRead と同じ)。
        // モーダルの裏の行は枠で別の文字を読むので採らない
        let ocrText: String?
        if matchedText == nil {
            ocrText = element.label.flatMap { label in label.isEmpty ? nil : (OCROnlyVisibility.mergedLabelHead(label) ?? label) }
        } else {
            ocrText = textToVerify.isEmpty ? nil : textToVerify
        }
        if flip == nil, !pixelsShowedTextThisStep, occlusionOCRMode == .on,
           noteCodesThisStep.subtracting(notesBefore).isDisjoint(with: Self.unverifiedVisibilityNotes),
           let ocrText,
           let shot = try? await xcuitest.screenshot(),
           case .read(let readable, _) = await RegionText.resolveWithinBudget(
               expected: ocrText,
               pngData: shot,
               frame: element.frame, screen: tree.screen), readable {
            pixelsShowedTextThisStep = true
        }
        guard flip == nil, pixelsShowedTextThisStep, noteCodesThisStep.subtracting(notesBefore).isDisjoint(with: Self.unverifiedVisibilityNotes) else {
            noteCodesThisStep.insert(.xcuitestTreeUnverified)
            return nil
        }
        return element
    }

    /// アプリの XCUITest の木を1回読む(DR-199・DR-202 の照会が共有する読み口)。
    /// XCUITest の snapshot は対象を activate する = 前面を離れたアプリを引き戻すので、activate しない /appstate で前面を確かめてから読む。
    /// 前面に無い → 注記なしの nil / 確認が答えない・木を読めない → `xcuitestTreeUnread` を立てた nil
    func readAppXCUITestTree(xcuitest: AppDriver, bundleID: String, phase: inout PhaseAccumulator) async -> SnapshotResponse? {
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
        return tree
    }

    /// 否定形(notExist / waitForClose)が in-app の木で「無い」と結論する直前の照会の答え(DR-199)
    enum ScopedAbsenceVerdict: Equatable {
        /// 照会の条件に当たらない(スコープの容器が子を持つ・スコープ無し・Android・xcuitest モード)
        case notApplicable
        /// 条件には当たったが答えられなかった(前面に無い・木を読めない)= 従来どおり「無い」を結論する(注記 `xcuitest-tree-unread` が残る)
        case unanswered
        case absent
        case stillThere
    }

    /// セレクタ(主・フォールバック)のスコープ(`>>`)の容器が in-app の木で解決できたのに子孫が空か。
    /// iOS の Compose の ScrollableTabRow・PullToRefreshBox は容器の直後に同じ枠の `other` が兄弟で並び子が浅い depth になるので
    /// `scopeDescendants` が空を返し、居る要素が「無い」に見える(DR-199)。**全ての notExist に照会を足すと遅い**ので、この形だけに絞る
    static func scopeContainerIsChildless(_ step: FlowStep, in elements: [ElementInfo]) -> Bool {
        ([step.locator] + (step.fallbacks ?? []).map { Optional($0) }).contains { locator in
            guard let locator else { return false }
            return LocatorResolver.childlessScopeContainer(of: locator, in: elements) != nil
        }
    }

    /// 否定形が in-app の木で不在と見たとき、スコープの容器が空の形だけアプリの XCUITest の木を1回照会し、居れば `.stillThere`。
    /// 費用: 前面の確認 `/appstate` 1回 + XCUITest の snapshot 1回(数百 ms〜1 秒台)を、条件に当たる notExist が不在を結論する周ごとに払う。
    /// 見えているかは見ない(notExist は「木に無い」を確かめる = 可視性検証を掛けない。DR-199 の肯定側とは判定軸が逆)
    func scopedAbsenceConsult(step: FlowStep, snapshot: SnapshotResponse,
                              phase: inout PhaseAccumulator) async -> ScopedAbsenceVerdict {
        guard !isAndroid, let xcuitest = typeDriver, let bundleID = launchedBundleID,
              Self.scopeContainerIsChildless(step, in: snapshot.elements) else { return .notApplicable }
        guard let tree = await readAppXCUITestTree(xcuitest: xcuitest, bundleID: bundleID, phase: &phase) else { return .unanswered }
        guard LocatorResolver.resolve(step: step, in: tree, strictForAssert: true) != nil else {
            noteCodesThisStep.insert(.xcuitestTreeNoMatch)
            return .absent
        }
        noteCodesThisStep.insert(.absenceContradictedByXCUITestTree)
        return .stillThere
    }

    /// 肯定形(countIs・select・送りの探索の各周)の解決用に、スコープの容器が in-app の木で空の形だけアプリの XCUITest の木を1回読んで返す(DR-199)。
    /// 否定形(`scopedAbsenceConsult`)と同じ条件・同じ読み口。**ref はその木を撮った XCUITest ドライバでだけ有効**なので、
    /// 撃つ操作に使うなら `appXCUITestTreeActionTarget` のようにドライバごと渡す。前面に無い・読めない = nil(従来どおり in-app の木で決める)
    func scopedPresenceTree(step: FlowStep, snapshot: SnapshotResponse, phase: inout PhaseAccumulator) async -> SnapshotResponse? {
        guard !isAndroid, let xcuitest = typeDriver, let bundleID = launchedBundleID,
              Self.scopeContainerIsChildless(step, in: snapshot.elements) else { return nil }
        return await readAppXCUITestTree(xcuitest: xcuitest, bundleID: bundleID, phase: &phase)
    }

    /// 肯定形の検証(exist・テキスト比較・enabled・checked)の各周で in-app の木では解けなかったとき、`scopedPresenceTree` の条件の形だけ
    /// XCUITest の木で解く。解けたら `snapshot` をその木に差し替える(以後の読み・遮蔽の検証・失敗時の木はその木 = 要素と同じ木)
    func resolveScopedViaXCUITestTree(step: FlowStep, snapshot: inout SnapshotResponse, phase: inout PhaseAccumulator) async
        -> (element: ElementInfo, usedFallback: FlowLocator?, quality: LocatorResolver.MatchQuality)? {
        guard let tree = await scopedPresenceTree(step: step, snapshot: snapshot, phase: &phase),
              let found = LocatorResolver.resolveDetailed(step: step, in: tree, strictForAssert: true) else { return nil }
        snapshot = tree
        noteCodesThisStep.insert(.scopeResolvedViaXCUITestTree)
        return found
    }

    /// 操作(tap・type 等)の対象が in-app の木で解けなかったとき、キーボードを閉じる・赤にする前にアプリの XCUITest の木を1回照会する。
    /// 見つかって **XCUITest が押せる(`isHittable`)と答えた**ときだけ、その木とドライバで撃つ(XCUITest の木はモーダルの裏の要素も残す =
    /// 見つかっただけでは採らない。押せるかの判定はデバイスの答えに任せる)。標準アプリのリマインダーの新規行の入力欄は in-app の木に
    /// 出ず、XCUITest の木にだけ出た。前面の確かめは `appXCUITestTreeMatch` と同じ(XCUITest の木の読みは activate する)
    func appXCUITestTreeActionTarget(step: FlowStep, action: String,
                                     phase: inout PhaseAccumulator) async -> (element: ElementInfo, usedFallback: FlowLocator?,
                                                                             snapshot: SnapshotResponse, driver: AppDriver)? {
        guard !isAndroid, let xcuitest = typeDriver, let bundleID = launchedBundleID,
              PreFireGuard.keyboardSensitiveActions.contains(action) else { return nil }
        guard let tree = await readAppXCUITestTree(xcuitest: xcuitest, bundleID: bundleID, phase: &phase) else { return nil }
        guard let (element, usedFallback) = LocatorResolver.resolve(step: step, in: tree),
              (try? await xcuitest.hitTest(ref: element.ref)) == .hittable(true) else { return nil }
        noteCodesThisStep.insert(.actedViaXCUITestTree)
        return (element, usedFallback, tree, xcuitest)
    }
}
