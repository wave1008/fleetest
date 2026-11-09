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
    public static let runnerEmptyRefusalPrefix = "could not empty the field"

    /// OCR の読みの上限(秒)。XCUITest ランナーの消去の読み返しの締め切り(BridgeRouter+TextInput.swift の
    /// `clearBudgetSeconds` = 8)と揃える = 同じ「消えたかの読み返し」。尽きたら判断不能 = 赤のまま(失敗文に理由)
    static let clearReadbackBudgetSeconds: TimeInterval = 8

    public struct ClearResidualAnswer {
        /// 欄に残っていると読んだ値(nil = 読めなかった・空)
        public var residual: String?
        public var notDrawn: Bool
        /// 判断できなかった理由(事実だけ。notDrawn・drawn のときは nil。residual が nil のときも理由を持つ)
        public var why: String?
        /// 確かめで最後に撮った木(撮れなかったら nil)
        public var snapshot: SnapshotResponse?
        /// drawn のとき、飾りの文字の他に読めた行(赤の失敗文に添える事実)
        public var drawnLines: [String] = []

        public init(residual: String?, notDrawn: Bool, why: String?, snapshot: SnapshotResponse?, drawnLines: [String] = []) {
            self.residual = residual
            self.notDrawn = notDrawn
            self.why = why
            self.snapshot = snapshot
            self.drawnLines = drawnLines
        }
    }

    /// `residual` が nil なら欄の現在の value を残りとして使う(ブリッジの 422 の経路)
    func checkClearResidual(_ treeDriver: AppDriver, residual: String?,
                            locate: (SnapshotResponse) -> ElementInfo?) async -> ClearResidualAnswer {
        await Self.readClearResidual(treeDriver, residual: residual, locate: locate)
    }

    /// 判定の中核(DSL の `checkClearResidual` と MCP の ft_clear_input が共有。文言は呼び手ごと)
    public static func readClearResidual(_ treeDriver: AppDriver, residual: String?,
                                         locate: (SnapshotResponse) -> ElementInfo?) async -> ClearResidualAnswer {
        func undetermined(_ why: String, _ residual: String? = nil, _ snap: SnapshotResponse? = nil) -> ClearResidualAnswer {
            ClearResidualAnswer(residual: residual, notDrawn: false, why: why, snapshot: snap)
        }
        guard let snap = try? await treeDriver.snapshot() else { return undetermined("the screen could not be captured") }
        guard let field = locate(snap) else { return undetermined("the field was not found on the screen afterwards", residual, snap) }
        let left = residual ?? field.value
        guard let left, !left.isEmpty, left != field.placeholder else {
            // 422 を撃ったランナーの読みと食い違う(木では空・placeholder と同じ)。事実として言う(黙ると赤の文に確かめた形跡が無い)
            return undetermined("the field's value reads as empty (or as its placeholder) in the tree taken afterwards,"
                                + " so there was no value to compare with the screen", nil, snap)
        }
        if let reason = ClearResidualDrawn.unreadableReason(field: field, screen: snap.screen, keyboard: snap.keyboardFrame) {
            return undetermined(reason, left, snap)
        }
        if let override = Self.clearResidualDrawnOverrideForTesting {
            let answer = override(left)
            guard let drawn = answer.drawn else { return undetermined(answer.fact ?? "OCR was unavailable", left, snap) }
            return ClearResidualAnswer(residual: left, notDrawn: !drawn, why: nil, snapshot: snap,
                                       drawnLines: drawn ? answer.fact.map { [$0] } ?? [] : [])
        }
        guard OCRSupport.isSupported else { return undetermined(OCRSupport.requirement, left, snap) }
        guard let png = try? await treeDriver.screenshot(), !png.isEmpty else {
            return undetermined("the screen could not be captured", left, snap)
        }
        if BlankFrameDetector.isBlackApartFromSystemBars(pngData: png) {
            return undetermined("the screenshot was black apart from the system bars", left, snap)
        }
        if let size = ClearResidualDrawn.pixelSize(png: png),
           let reason = ClearResidualDrawn.orientationReason(imageWidth: size.width, imageHeight: size.height, screen: snap.screen) {
            return undetermined(reason, left, snap)
        }
        _ = await RegionText.awaitModelCompile(mode: .on)
        // 待ったコンパイルの時間は予算に含めない
        let frame = field.frame, screen = snap.screen
        let outcome = await TaskBudget.run(.milliseconds(Int(Self.clearReadbackBudgetSeconds * 1000))) {
            await Self.readFieldLines(png: png, frame: frame, screen: screen)
        }
        let readLines: [String]
        switch outcome {
        case .exhausted: return undetermined("reading the field's area ran out of time", left, snap)
        case .value(nil): return undetermined("the field's area could not be read (OCR returned no reading)", left, snap)
        case .value(let lines?): readLines = lines
        }
        let treeTexts = ClearResidualDrawn.treeTexts(field: field, in: snap.elements)
        if readLines.isEmpty, !(await RegionText.readerIsAlive()) {
            return undetermined(Self.ocrDeadFact, left, snap)
        }
        let lines = ClearResidualDrawn.remainingLines(ocrLines: readLines, treeTexts: treeTexts)
        return ClearResidualAnswer(residual: left, notDrawn: lines.isEmpty, why: nil, snapshot: snap, drawnLines: lines)
    }

    /// 消え残りと読んだ値を OCR で確かめた結果の ClearOutcome。描かれていなければ緑(注記つき)・それ以外は今まで通り赤。
    /// `handsOverSnapshot` = `treeDriver` が呼び手の actingDriver のとき true(確かめの木から ref を引き直せる)
    func residualClearOutcome(_ treeDriver: AppDriver, residual: String,
                              locate: (SnapshotResponse) -> ElementInfo?, fallback: String?,
                              handsOverSnapshot: Bool) async -> ClearOutcome {
        let answer = await checkClearResidual(treeDriver, residual: residual, locate: locate)
        if answer.notDrawn { return clearedAsResidualNotDrawn(answer, fallback: fallback, handsOverSnapshot: handsOverSnapshot) }
        return .failed("clearInput reported success but the value remained: \"\(residual)\"" + Self.screenFact(answer))
    }

    /// 欄の枠を拡大の段ごとに全部読み、読めた行を全段ぶん集める(nil = 1段も読めなかった = 画像不正・OCR の失敗)。
    /// `RegionText.resolve` を使わない —— あれは期待文字列が読めた段で止まり、0行の段で前の段の行を捨てて返す
    /// (ここで見るのは「何か1行でも描かれているか」なので、どの段の行も捨てられない)。
    /// 余白は 0: 枠の外の文字(取消ボタン・一覧の行)を拾うと、空の欄を赤にする。言語は既定の ja+en(value は中身ではない)
    static func readFieldLines(png: Data, frame: FTRect, screen: FTRect) async -> [String]? {
        var lines: [String] = []
        var readAny = false
        for step in RegionText.upscaleLadder {
            guard let reading = await RegionText.read(pngData: png, frame: frame, screen: screen, cropPadding: 0,
                                                      languages: RegionText.defaultLanguages, upscale: step) else { continue }
            readAny = true
            lines += reading.lines
        }
        return readAny ? lines : nil
    }

    /// 赤の失敗文に添える、画面で確かめた事実(確かめていなければ理由)
    public static func screenFact(_ answer: ClearResidualAnswer) -> String {
        if let why = answer.why { return " (not checked against the screen: \(why))" }
        guard !answer.drawnLines.isEmpty else { return "" }
        return " (the field on screen still shows text (OCR): "
            + answer.drawnLines.map { "\"\($0)\"" }.joined(separator: ", ") + ")"
    }

    /// XCUITest ブリッジの 422「could not empty the field」を、絵の上で欄が空のとき緑にする。
    /// `cleared` が nil なら呼び手は `error` を使い続ける(422 でなければ元のまま。確かめた 422 は同じ case のまま本文に事実を足す)
    func recoveredEmptyRefusal(_ error: Error, _ treeDriver: AppDriver,
                               locate: (SnapshotResponse) -> ElementInfo?, fallback: String?,
                               handsOverSnapshot: Bool) async -> (cleared: ClearOutcome?, error: Error) {
        guard case DriverError.badResponse(422, let body) = error, body.hasPrefix(Self.runnerEmptyRefusalPrefix) else {
            return (nil, error)
        }
        let answer = await checkClearResidual(treeDriver, residual: nil, locate: locate)
        if answer.residual != nil, answer.notDrawn {
            return (clearedAsResidualNotDrawn(answer, fallback: fallback, handsOverSnapshot: handsOverSnapshot), error)
        }
        return (nil, DriverError.badResponse(status: 422, body: body + Self.screenFact(answer)))
    }

    private func clearedAsResidualNotDrawn(_ answer: ClearResidualAnswer, fallback: String?,
                                           handsOverSnapshot: Bool) -> ClearOutcome {
        noteCodesThisStep.insert(.clearResidualNotDrawn)
        return .cleared(driverFallback: Self.joinNotes(fallback, StepNote.clearResidualNotDrawn.text),
                        actingDriverSnapshot: handsOverSnapshot ? answer.snapshot : nil)
    }

    /// ロケータ無しの消去で覚えた欄を、確かめの木で identifier 優先・無ければ frame 一致で引き直す
    public static func matchFocused(_ before: ElementInfo, in snapshot: SnapshotResponse) -> ElementInfo? {
        if let identifier = before.identifier { return snapshot.elements.first { $0.identifier == identifier } }
        return snapshot.elements.first { $0.frame == before.frame }
    }
}
