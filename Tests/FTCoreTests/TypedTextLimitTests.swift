import XCTest
@testable import FTCore

/// `type` の文字数の上限(`BridgeAPI.maxTypeCharacters`)。DSL(FlowStep → executeAction の入口)と MCP(ft_type)が同じ判定を通る
final class TypedTextLimitTests: XCTestCase {

    func testLimitIsPinned() {
        XCTAssertEqual(BridgeAPI.maxTypeCharacters, 1000)
        // 根拠の式: 28ms/字 × 上限 × 打ち直し 2 倍 < ランナーの見張り 75 秒
        XCTAssertLessThan(0.028 * Double(BridgeAPI.maxTypeCharacters) * 2, 75)
    }

    func testExactlyAtTheLimitPassesAndOneOverIsRefused() {
        XCTAssertNil(ArgumentBounds.typedTextViolation(String(repeating: "a", count: 1000)))
        let message = ArgumentBounds.typedTextViolation(String(repeating: "a", count: 1001))
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("1000") == true && message?.contains("split") == true, message ?? "")
    }

    func testCountsGraphemeClusters() {
        XCTAssertNil(ArgumentBounds.typedTextViolation(String(repeating: "🙂", count: 1000)))
        XCTAssertNotNil(ArgumentBounds.typedTextViolation(String(repeating: "🙂", count: 1001)))
    }

    func testFlowStepChecksOnlyTypeActions() {
        let long = String(repeating: "x", count: 1001)
        XCTAssertNotNil(FlowStep.typedTextViolation(action: "type", text: long))
        XCTAssertNil(FlowStep.typedTextViolation(action: "type", text: String(repeating: "x", count: 1000)))
        XCTAssertNil(FlowStep.typedTextViolation(action: "type", text: nil))
        XCTAssertNil(FlowStep.typedTextViolation(action: "tap", text: long))
    }

    /// executeAction の入口が判定を通る(ゲートより前に device へ触らない)
    func testExecuteActionEntryCallsTheCheckBeforeTouchingTheDevice() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/StepExecutor+Actions.swift"),
                                encoding: .utf8)
        let entry = try XCTUnwrap(source.range(of: "func executeAction("))
        let check = try XCTUnwrap(source.range(of: "FlowStep.typedTextViolation(action: action", range: entry.upperBound..<source.endIndex))
        let device = try XCTUnwrap(source.range(of: "cachedScreenshot = nil", range: entry.upperBound..<source.endIndex))
        XCTAssertLessThan(check.lowerBound, device.lowerBound)
    }
}
