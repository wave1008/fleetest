// ft_swipe(scrollFrame:) の下書きへ残す手と、ft_scroll_to の位置指定セレクタの注記。
// デバイス無しで判定できる純関数だけを固定する。

import XCTest
@testable import FTCore
@testable import fleetest_mcp

final class MCPSwipeRecordedStepTests: XCTestCase {
    private let locator = FTSelector.parse("#sw_row_1").primary

    private func recorded(_ direction: FTSwipeDirection, declares: Bool?) -> FlowStep {
        let arg = MCPServer.ScrollFrameArg(locator: locator, declaresScrollable: declares)
        let step = MCPServer.swipeScrollFrameStep(direction: direction, scrollFrameArg: arg)
        return MCPServer.swipeRecordedStep(direction: direction, scrollFrameArg: arg,
                                           locator: locator, scrollStep: step)
    }

    func testScrollableFrameKeepsScrollStep() {
        for declares in [true, nil] as [Bool?] {
            let step = recorded(.left, declares: declares)
            XCTAssertEqual(step.action, "scroll")
            XCTAssertEqual(step.direction, "left")
        }
    }

    func testNonScrollableFrameRecordsSwipeByWithFingerSign() {
        let expected: [(FTSwipeDirection, Double, Double)] = [
            (.left, -0.5, 0), (.right, 0.5, 0), (.up, 0, -0.5), (.down, 0, 0.5)]
        for (direction, dx, dy) in expected {
            let step = recorded(direction, declares: false)
            XCTAssertEqual(step.action, "swipeBy")
            XCTAssertEqual(step.dxRatio, dx)
            XCTAssertEqual(step.dyRatio, dy)
            XCTAssertEqual(step.locator?.summary, locator.summary)
        }
    }

    func testNonScrollableFrameGeneratesSwipeByLine() {
        let line = ScenarioCodeGen.command(for: recorded(.left, declares: false)) ?? ""
        XCTAssertTrue(line.hasPrefix("swipeBy("), line)
        XCTAssertTrue(line.contains("dxRatio: -0.5"), line)
        XCTAssertTrue(line.contains("dyRatio: 0"), line)
        XCTAssertFalse(line.contains("scroll"), line)
    }

    func testPositionalSelectorNote() {
        func note(_ text: String) -> String {
            MCPServer.positionalSelectorNote(selector: FTSelector.parse(text), selectorText: text)
        }
        XCTAssertTrue(note(".clickable[12]").contains("picks by position"))
        XCTAssertEqual(note("#row_12"), "")
        XCTAssertEqual(note("#list >> .clickable[2]"), "")
        XCTAssertEqual(note("Settings"), "")
    }
}
