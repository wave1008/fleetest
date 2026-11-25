// occlusion-guard: in-app ブリッジが「タイトルを描いている」と申告したボタンだけ可視性検証の対象に入る。
import XCTest
@testable import FTCore

extension StepExecutorTests {

    private func titleButton(drawnTitle: String?, label: String = "保存") -> [ElementInfo] {
        var pane = ElementInfo(ref: 0, type: "scrollView", identifier: "pane", label: nil, value: nil,
                               placeholder: nil, enabled: true,
                               frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 0)
        pane.scrollable = true
        let button = ElementInfo(ref: 1, type: "button", identifier: "btn", label: label, value: nil,
                                 placeholder: nil, enabled: true,
                                 frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 1,
                                 drawnTitle: drawnTitle)
        return [pane, button]
    }

    /// ボタンを textEquals で確かめたときの判定と、可視性の段(FM)へ回った回数
    private func titleButtonOutcome(_ tree: [ElementInfo]) async -> (StepResult.Status, Int) {
        let primary = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [tree],
                                    screenshots: [StepExecutorTests.inkedPNG])
        let delegate = FakeVisibilityDelegate(visible: false)
        let executor = StepExecutor(driver: primary, delegate: delegate, occlusionOCRMode: .on,
                                    isAndroid: false, tunables: RunTunables())
        executor.noteAppLaunched()
        let step = FlowStep(assert: "textEquals", locator: FlowLocator(id: "btn"),
                            expected: "保存", timeout: 0, occlusionGuard: true)
        let outcome = await executor.execute(step)
        return (outcome.status, delegate.visibleCalls)
    }

    func testButtonThatDeclaresItsDrawnTitleGoesThroughTheVisibilityCheck() async {
        let (status, calls) = await titleButtonOutcome(titleButton(drawnTitle: "保存"))
        XCTAssertGreaterThan(calls, 0)
        guard case .failed = status else { XCTFail("読めない文字は赤のはず: \(status)"); return }
    }

    func testButtonWithoutDrawnTitleStaysPassThrough() async {
        let (_, calls) = await titleButtonOutcome(titleButton(drawnTitle: nil))
        XCTAssertEqual(calls, 0)
    }

    func testButtonWhoseDrawnTitleDiffersFromTheExpectedStaysPassThrough() async {
        let (_, calls) = await titleButtonOutcome(titleButton(drawnTitle: "別の文字"))
        XCTAssertEqual(calls, 0)
    }

    func testDrawsOwnTitleRuleIsPure() {
        let on = titleButton(drawnTitle: "保存")[1]
        XCTAssertTrue(OcclusionEligibility.drawsOwnTitle(on, expectedText: "保存"))
        XCTAssertFalse(OcclusionEligibility.drawsOwnTitle(on, expectedText: ""))
        XCTAssertFalse(OcclusionEligibility.drawsOwnTitle(on, expectedText: "別"))
    }

    func testDrawnTitleSurvivesTheWireAndIsOptional() throws {
        let sent = titleButton(drawnTitle: "保存")[1]
        let back = try JSONDecoder().decode(ElementInfo.self, from: JSONEncoder().encode(sent))
        XCTAssertEqual(back.drawnTitle, "保存")
        let bare = try JSONDecoder().decode(ElementInfo.self, from: JSONEncoder().encode(titleButton(drawnTitle: nil)[1]))
        XCTAssertNil(bare.drawnTitle)
    }
}
