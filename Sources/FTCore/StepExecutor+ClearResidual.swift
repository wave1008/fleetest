import Foundation

/// clearInput の事後検証が消え残りと読んだとき、欄の絵を OCR して 2 つ目の材料にする(判定は `ClearResidualDrawn`)。
/// value が入力を映さない欄(M3 SearchBar の iOS)で、空になった欄を赤にしないための確かめ。
/// type の `typedTextIsOnScreen` の対。**判断できない理由は全部「今まで通り赤」**(OCR は macOS 26 では recognize が投げる)
extension StepExecutor {

    /// テスト用(本番では nil)。OCR を撃たずに「残りが描かれていたか」を差し替える。drawn=nil は判断不能
    nonisolated(unsafe) static var clearResidualDrawnOverrideForTesting:
        ((String) -> (drawn: Bool?, fact: String?))?

    /// XCUITest ランナーの消去の 422 の先頭。Runner/FleetestRunnerUITests/BridgeRouter+TextInput.swift の
    /// `BridgeError(422, "could not empty the field …")` と同期(Runner の文言を変えたらここも)
    static let runnerEmptyRefusalPrefix = "could not empty the field"

    struct ClearResidualAnswer {
        /// 欄に残っていると読んだ値(nil = 読めなかった・空)
        var residual: String?
        var notDrawn: Bool
        /// 判断できなかった理由(事実だけ。notDrawn・drawn のときは nil)
        var why: String?
        /// 確かめで最後に撮った木(撮れなかったら nil)
        var snapshot: SnapshotResponse?
    }

    /// `residual` が nil なら欄の現在の value を残りとして使う(ブリッジの 422 の経路)
    func checkClearResidual(_ treeDriver: AppDriver, residual: String?,
                            locate: (SnapshotResponse) -> ElementInfo?) async -> ClearResidualAnswer {
        func undetermined(_ why: String, _ residual: String? = nil, _ snap: SnapshotResponse? = nil) -> ClearResidualAnswer {
            ClearResidualAnswer(residual: residual, notDrawn: false, why: why, snapshot: snap)
        }
        guard let snap = try? await treeDriver.snapshot() else { return undetermined("the screen could not be captured") }
        guard let field = locate(snap) else { return undetermined("the field was not found on the screen afterwards", residual, snap) }
        let left = residual ?? field.value
        guard let left, !left.isEmpty, left != field.placeholder else {
            return ClearResidualAnswer(residual: nil, notDrawn: false, why: nil, snapshot: snap)
        }
        if let reason = ClearResidualDrawn.unreadableReason(field: field, screen: snap.screen, keyboard: snap.keyboardFrame) {
            return undetermined(reason, left, snap)
        }
        if let override = Self.clearResidualDrawnOverrideForTesting {
            let answer = override(left)
            guard let drawn = answer.drawn else { return undetermined(answer.fact ?? "OCR was unavailable", left, snap) }
            return ClearResidualAnswer(residual: left, notDrawn: !drawn, why: nil, snapshot: snap)
        }
        guard OCRSupport.isSupported else { return undetermined(OCRSupport.requirement, left, snap) }
        guard let png = try? await treeDriver.screenshot(), !png.isEmpty else {
            return undetermined("the screen could not be captured", left, snap)
        }
        if BlankFrameDetector.isBlackApartFromSystemBars(pngData: png) {
            return undetermined("the screenshot was black apart from the system bars", left, snap)
        }
        _ = await RegionText.awaitModelCompile(mode: .on)
        // 予算は type の読み返しの締め切りと同じ長さ(新しい定数を置かない)。待ったコンパイルの時間は含めない
        let budget = Duration.milliseconds(Int(Self.typeVerifyBudgetSeconds * 1000))
        let result = await RegionText.resolveWithinBudget(
            expected: left, pngData: png, frame: field.frame, screen: snap.screen, budget: budget)
        let reading: RegionText.Reading
        switch result {
        case .read(_, let read): reading = read
        case .unreadable: return undetermined("the field's area could not be read (OCR returned no reading)", left, snap)
        case .budgetExhausted: return undetermined("reading the field's area ran out of time", left, snap)
        }
        if reading.lines.isEmpty, !(await RegionText.readerIsAlive()) {
            return undetermined(Self.ocrDeadFact, left, snap)
        }
        let verdict = ClearResidualDrawn.judge(
            residual: left, ocrLines: reading.lines,
            treeTexts: ClearResidualDrawn.treeTexts(field: field, in: snap.elements))
        return ClearResidualAnswer(residual: left, notDrawn: verdict == .notDrawn, why: nil, snapshot: snap)
    }

    /// 消え残りと読んだ値を OCR で確かめた結果の ClearOutcome。描かれていなければ緑(注記つき)・それ以外は今まで通り赤。
    /// `handsOverSnapshot` = `treeDriver` が呼び手の actingDriver のとき true(確かめの木から ref を引き直せる)
    func residualClearOutcome(_ treeDriver: AppDriver, residual: String,
                              locate: (SnapshotResponse) -> ElementInfo?, fallback: String?,
                              handsOverSnapshot: Bool) async -> ClearOutcome {
        let answer = await checkClearResidual(treeDriver, residual: residual, locate: locate)
        if answer.notDrawn { return clearedAsResidualNotDrawn(answer, fallback: fallback, handsOverSnapshot: handsOverSnapshot) }
        return .failed("clearInput reported success but the value remained: \"\(residual)\""
            + (answer.why.map { " (not checked against the screen: \($0))" } ?? ""))
    }

    /// XCUITest ブリッジの 422「could not empty the field」を、欄の value が入力を映さないだけのとき緑にする。
    /// nil = 元のエラーを投げ直す(422 でない・欄が空と読めた・描かれている・判断不能)
    func recoveredEmptyRefusal(_ error: Error, _ treeDriver: AppDriver,
                               locate: (SnapshotResponse) -> ElementInfo?, fallback: String?,
                               handsOverSnapshot: Bool) async -> ClearOutcome? {
        guard case DriverError.badResponse(422, let body) = error, body.hasPrefix(Self.runnerEmptyRefusalPrefix) else { return nil }
        let answer = await checkClearResidual(treeDriver, residual: nil, locate: locate)
        guard answer.residual != nil, answer.notDrawn else { return nil }
        return clearedAsResidualNotDrawn(answer, fallback: fallback, handsOverSnapshot: handsOverSnapshot)
    }

    private func clearedAsResidualNotDrawn(_ answer: ClearResidualAnswer, fallback: String?,
                                           handsOverSnapshot: Bool) -> ClearOutcome {
        noteCodesThisStep.insert(.clearResidualNotDrawn)
        return .cleared(driverFallback: Self.joinNotes(fallback, StepNote.clearResidualNotDrawn.text),
                        actingDriverSnapshot: handsOverSnapshot ? answer.snapshot : nil)
    }

    /// ロケータ無しの消去で覚えた欄を、確かめの木で identifier 優先・無ければ frame 一致で引き直す
    static func matchFocused(_ before: ElementInfo, in snapshot: SnapshotResponse) -> ElementInfo? {
        if let identifier = before.identifier { return snapshot.elements.first { $0.identifier == identifier } }
        return snapshot.elements.first { $0.frame == before.frame }
    }
}
