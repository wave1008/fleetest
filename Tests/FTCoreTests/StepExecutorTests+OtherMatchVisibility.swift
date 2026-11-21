// exist の可視性検証が最初の一致で赤になったとき、同じセレクタの残りの一致を同じ検証へ通す(`visibleOtherMatch`)。
// 実例: SUT Store Android のカートで、商品画像の説明ラベルが文字の型で木に出て(商品名と同じラベル・木の順で先)、
// 画像の枠を検証して赤になった(シナリオ作成の評価 6回目・11/22 に手元の Emulator で測定)
import XCTest
@testable import FTCore

extension StepExecutorTests {

    private func sameLabelPair() -> [ElementInfo] {
        [ElementInfo(ref: 1, type: "staticText", identifier: nil, label: "深夜の訪問者", value: nil,
                     placeholder: nil, enabled: true, frame: FTRect(x: 1, y: 1, width: 60, height: 60), depth: 3),
         ElementInfo(ref: 2, type: "staticText", identifier: nil, label: "深夜の訪問者", value: nil,
                     placeholder: nil, enabled: true, frame: FTRect(x: 70, y: 1, width: 100, height: 20), depth: 2)]
    }

    /// 最初の一致(画像)は見えない・2つ目(文字)は見える → 緑。OCR を切った構成では最初の一致で空の転写の訊き直しが
    /// 1回入るので、2つ目の一致の検証は3回目の呼び出し
    func testExistPassesWhenAnotherMatchOfTheSameSelectorIsVisible() async throws {
        let primary = FakeAppDriver(name: "primary", log: CallLog(),
                                    snapshotElements: [sameLabelPair()], screenshots: [Self.inkedPNG])
        let delegate = FakeVisibilityDelegate(visible: false)
        delegate.visibleFromCall = 3
        let executor = StepExecutor(driver: primary, delegate: delegate, occlusionInkThreshold: 10_000,
                                    occlusionOCRMode: .off, isAndroid: true, tunables: RunTunables())
        let outcome = await executor.execute(FlowStep(assert: "exists", locator: FlowLocator(label: "深夜の訪問者"),
                                                      timeout: 0, occlusionGuard: true))
        guard case .passed = outcome.status else { return XCTFail("別の一致は見えているのに赤: \(outcome.status)") }
        XCTAssertEqual(delegate.visibleCalls, 3)
    }

    /// 文字の検証(textIs 系)も同じ: 最初の一致が見えなくても、値が答えに合う別の一致の文字が見えていれば緑
    func testTextAssertionPassesWhenAnotherMatchingElementIsVisible() async throws {
        let primary = FakeAppDriver(name: "primary", log: CallLog(),
                                    snapshotElements: [sameLabelPair()], screenshots: [Self.inkedPNG])
        let delegate = FakeVisibilityDelegate(visible: false)
        delegate.visibleFromCall = 3
        let executor = StepExecutor(driver: primary, delegate: delegate, occlusionInkThreshold: 10_000,
                                    occlusionOCRMode: .off, isAndroid: true, tunables: RunTunables())
        let outcome = await executor.execute(FlowStep(assert: "textEquals", locator: FlowLocator(label: "深夜の訪問者"),
                                                      expected: "深夜の訪問者", timeout: 0, occlusionGuard: true))
        guard case .passed = outcome.status else { return XCTFail("別の一致は見えているのに赤: \(outcome.status)") }
        XCTAssertEqual(delegate.visibleCalls, 3)
    }

    /// 序数で1つに決めたセレクタは、残りの一致を見ない(書き手が「どの1つか」を決めている)
    func testExistWithAnIndexDoesNotTryOtherMatches() async throws {
        let primary = FakeAppDriver(name: "primary", log: CallLog(),
                                    snapshotElements: [sameLabelPair()], screenshots: [Self.inkedPNG])
        let delegate = FakeVisibilityDelegate(visible: false)
        delegate.visibleFromCall = 3
        let executor = StepExecutor(driver: primary, delegate: delegate, occlusionInkThreshold: 10_000,
                                    occlusionOCRMode: .off, isAndroid: true, tunables: RunTunables())
        var locator = FlowLocator(label: "深夜の訪問者")
        locator.index = 0
        let outcome = await executor.execute(FlowStep(assert: "exists", locator: locator,
                                                      timeout: 0, occlusionGuard: true))
        guard case .failed = outcome.status else { return XCTFail("序数のセレクタが別の一致で緑: \(outcome.status)") }
        XCTAssertEqual(delegate.visibleCalls, 2, "序数のセレクタで残りの一致を検証した")
    }
}
