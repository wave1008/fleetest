// occlusion-guard: 文字の型でない要素(行の clickable・ボタン)は、同じ label の文字の子をちょうど1つ持つとき
// その子で可視性を確かめる。親は切れて文字が消えていても枠の位置にインクがあるので足切りを通っていた。
import XCTest
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import FTCore

extension StepExecutorTests {

    private func rowTree(children: [(label: String, type: String)], scrollable: Bool = true) -> [ElementInfo] {
        var pane = ElementInfo(ref: 0, type: "scrollView", identifier: "pane", label: nil, value: nil,
                               placeholder: nil, enabled: true,
                               frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 0)
        pane.scrollable = scrollable
        let row = ElementInfo(ref: 1, type: "clickable", identifier: "row_01", label: "行 01", value: nil,
                              placeholder: nil, enabled: true,
                              frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 1)
        var tree = [pane, row]
        for (i, c) in children.enumerated() {
            tree.append(ElementInfo(ref: 2 + i, type: c.type, identifier: nil, label: c.label, value: nil,
                                    placeholder: nil, enabled: true,
                                    frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 2))
        }
        return tree
    }

    /// 行を textEquals で確かめたときの判定と、可視性の段(FM)へ回った回数
    private func rowGuardOutcome(_ tree: [ElementInfo], isAndroid: Bool = false,
                                 rowType: String = "clickable",
                                 screenshot: Data = StepExecutorTests.inkedPNG,
                                 ocrMode: RegionTextGateMode = .on) async -> (StepResult.Status, Int, [StepNote]) {
        var tree = tree
        tree[1].type = rowType
        let primary = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [tree],
                                    screenshots: [screenshot])
        let delegate = FakeVisibilityDelegate(visible: false)
        let executor = StepExecutor(driver: primary, delegate: delegate, occlusionOCRMode: ocrMode,
                                    isAndroid: isAndroid, tunables: RunTunables())
        executor.noteAppLaunched()
        let step = FlowStep(assert: "textEquals", locator: FlowLocator(id: "row_01"),
                            expected: "行 01", timeout: 0, occlusionGuard: true)
        let outcome = await executor.execute(step)
        return (outcome.status, delegate.visibleCalls, outcome.notes)
    }

    func testRowWithOneSameLabelTextChildIsVerifiedThroughTheChild() async {
        let (status, calls, _) = await rowGuardOutcome(rowTree(children: [("行 01", "staticText")]))
        XCTAssertGreaterThan(calls, 0, "子の文字を縁の判定つきで読ませるはず")
        guard case .failed = status else { XCTFail("読めない文字は赤のはず: \(status)"); return }
    }

    /// 行の文字を描いた絵(Vision が実際に読む)。OCR の近道を撃たせるためモデルは準備済みとして扱う
    private func renderedRowPNG(_ text: String?) throws -> Data {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 400, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 800))
        if let text {
            let font = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            ])
            ctx.textPosition = CGPoint(x: 10, y: 745)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
        }
        let image = try XCTUnwrap(ctx.makeImage())
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    private func rowOCRTree(label: String = "Row One") -> [ElementInfo] {
        var tree = rowTree(children: [])
        tree[0].frame = FTRect(x: 0, y: 0, width: 400, height: 800)
        tree[1].frame = FTRect(x: 0, y: 0, width: 400, height: 80)
        tree[1].label = label
        return tree
    }

    private func withModelReady<T>(_ body: () async throws -> T) async rethrows -> T {
        let saved = RegionText.modelReadyOverrideForTesting
        RegionText.modelReadyOverrideForTesting = true
        defer { RegionText.modelReadyOverrideForTesting = saved }
        return try await body()
    }

    private func rowOCROutcome(_ png: Data, ocrMode: RegionTextGateMode = .on,
                               screenshots: ((Int) -> Void)? = nil) async -> (StepResult.Status, Int, [StepNote]) {
        var tree = rowOCRTree()
        tree[1].type = "clickable"
        let primary = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [tree], screenshots: [png])
        let delegate = FakeVisibilityDelegate(visible: false)
        let executor = StepExecutor(driver: primary, delegate: delegate, occlusionOCRMode: ocrMode,
                                    isAndroid: false, tunables: RunTunables())
        executor.noteAppLaunched()
        let outcome = await executor.execute(FlowStep(assert: "textEquals", locator: FlowLocator(id: "row_01"),
                                                      expected: "Row One", timeout: 0, occlusionGuard: true))
        screenshots?(primary.screenshotCallCount)
        return (outcome.status, delegate.visibleCalls, outcome.notes)
    }

    /// OCR が予算(`RegionText.occlusionBudget`)内に読み終えた回の結果。並列のテストの負荷で予算を超えると読みが無く、
    /// 行の確かめ自体が走らない(警告が出ない・出ないことの確かめも素通り)ので、その回は撃ち直し、3 回とも超えたらスキップする
    /// 予算を超えた読みが走り続けている間は近道を撃たない(`ocrShortcutBusy`)ので、その回も撃ち直し、撃つ前に走っている読みの終わりを待つ
    private func rowOCROutcomeWithinBudget(_ png: Data) async throws -> (StepResult.Status, Int, [StepNote]) {
        for _ in 0..<3 {
            await Self.awaitAbandonedOCRReads()
            let outcome = await withModelReady { await rowOCROutcome(png) }
            if !outcome.2.contains(.ocrBudgetExhausted), !outcome.2.contains(.ocrShortcutBusy) { return outcome }
        }
        throw XCTSkip("OCR exceeded its budget three times under load; the row check did not run")
    }

    /// 予算を超えて諦めた読み(`RegionText.abandonedInFlight`)が終わるまで待つ(上限 10 秒 = 単体で 100〜300ms の読みに十分)
    static func awaitAbandonedOCRReads() async {
        for _ in 0..<200 where RegionText.abandonedInFlight > 0 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// 別の文字が読めた行は警告(赤にしない)。FM は呼ばない
    func testRowReadAsOtherTextWarnsWithoutCallingFM() async throws {
        let png = try renderedRowPNG("Different Words")
        let (status, calls, notes) = try await rowOCROutcomeWithinBudget(png)
        XCTAssertEqual(calls, 0, "行の警告の段では FM を呼ばない \(status) \(notes)")
        guard case .passed = status else { XCTFail("警告にとどめるはず: \(status)"); return }
        XCTAssertTrue(notes.contains(.rowLabelNotRead), "\(notes)")
    }

    /// 1行も読めない行(文字を描かないセル)は警告しない。FM は呼ばない
    func testRowWithNoReadableTextHasNoWarningAndNoFM() async throws {
        let png = try renderedRowPNG(nil)
        let (status, calls, notes) = try await rowOCROutcomeWithinBudget(png)
        XCTAssertEqual(calls, 0)
        guard case .passed = status else { XCTFail("\(status)"); return }
        XCTAssertFalse(notes.contains(.rowLabelNotRead), "\(notes)")
    }

    /// 全部見えている行は注記なし
    func testRowFullyReadHasNoWarning() async throws {
        let png = try renderedRowPNG("Row One")
        let (_, calls, notes) = try await rowOCROutcomeWithinBudget(png)
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(notes.contains(.rowLabelNotRead), "\(notes)")
    }

    /// OCR の段が無効な構成では行の確かめ自体を走らせない(FM があっても呼ばない・絵も撮らない = 素通りの所要)
    func testRowCheckDoesNotRunWhenOCRIsOff() async throws {
        let png = try renderedRowPNG("Different Words")
        var shots = -1
        let (status, calls, notes) = await withModelReady { await rowOCROutcome(png, ocrMode: .off, screenshots: { shots = $0 }) }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(shots, 0, "行の確かめのために絵を撮った")
        guard case .passed = status else { XCTFail("\(status)"); return }
        XCTAssertFalse(notes.contains(.rowLabelNotRead))
    }

    func testRowLabelNotReadRuleIsPure() {
        XCTAssertFalse(OCROnlyVisibility.rowLabelNotRead(lines: nil, expected: "Row One"))
        XCTAssertFalse(OCROnlyVisibility.rowLabelNotRead(lines: [], expected: "Row One"))
        XCTAssertFalse(OCROnlyVisibility.rowLabelNotRead(lines: ["Row One"], expected: "Row One"))
        XCTAssertTrue(OCROnlyVisibility.rowLabelNotRead(lines: ["Other"], expected: "Row One"))
        XCTAssertTrue(OCROnlyVisibility.rowLabelNotRead(lines: ["Row"], expected: "Row One Two Three"), "先頭だけ")
    }

    /// Android は従来どおり(文字の子の無い行へ広げない)
    func testAndroidRowWithoutTextChildStaysPassThrough() async {
        let (_, calls, notes) = await rowGuardOutcome(rowTree(children: []), isAndroid: true)
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(notes.contains(.rowLabelNotRead))
    }

    /// 文字の子があるときは従来どおりその子で確かめて赤(警告にしない)
    func testRowWithTextChildStillFailsRedAndHasNoRowWarning() async {
        let (status, _, notes) = await rowGuardOutcome(rowTree(children: [("行 01", "staticText")]))
        guard case .failed = status else { XCTFail("\(status)"); return }
        XCTAssertFalse(notes.contains(.rowLabelNotRead))
    }

    func testLabelledRowRuleIsPure() {
        let bare = rowTree(children: [])
        XCTAssertTrue(OcclusionEligibility.isLabelledRowWithoutText(bare[1], expectedText: "行 01", in: bare))
        XCTAssertFalse(OcclusionEligibility.isLabelledRowWithoutText(bare[1], expectedText: "別", in: bare))
        let withOtherText = rowTree(children: [("別の文字", "staticText")])
        XCTAssertFalse(OcclusionEligibility.isLabelledRowWithoutText(withOtherText[1], expectedText: "行 01", in: withOtherText))
    }

    func testRowWithTwoSameLabelTextChildrenStaysPassThrough() async {
        let (_, calls, _) = await rowGuardOutcome(rowTree(children: [("行 01", "staticText"), ("行 01", "staticText")]))
        XCTAssertEqual(calls, 0)
    }

    func testRowWithDifferentLabelChildStaysPassThrough() async {
        let (_, calls, _) = await rowGuardOutcome(rowTree(children: [("別の文字", "staticText")]))
        XCTAssertEqual(calls, 0)
    }

    func testRowWithSameLabelNonTextChildStaysPassThrough() async {
        let (_, calls, _) = await rowGuardOutcome(rowTree(children: [("行 01", "image")]))
        XCTAssertEqual(calls, 0)
    }

    /// 縁の判定は子に対して効く: スクロール容器でなければ子はインクで素通り
    func testChildAwayFromAScrollEdgeIsStillPassedByInk() async {
        let (status, calls, _) = await rowGuardOutcome(rowTree(children: [("行 01", "staticText")], scrollable: false))
        XCTAssertEqual(calls, 0)
        guard case .passed = status else { XCTFail("\(status)"); return }
    }

    func testSameLabelTextDescendantIsTheSharedPureRule() {
        let tree = rowTree(children: [("行 01", "staticText")])
        XCTAssertEqual(OcclusionEligibility.sameLabelTextDescendant(
            of: tree[1], expectedText: "行 01", isUserText: true, in: tree)?.ref, 2)
        XCTAssertNil(OcclusionEligibility.sameLabelTextDescendant(
            of: tree[2], expectedText: "行 01", isUserText: true, in: tree), "文字の型自身は対象外")
    }
}
