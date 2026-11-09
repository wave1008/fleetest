import XCTest
@testable import FTCore
@testable import fleetest_mcp

/// ft_clear_input の 422「could not empty the field」の扱い(判定の中核は DSL と共有の StepExecutor.readClearResidual・文言は MCP 側)
final class ClearEmptyRefusalTests: XCTestCase {
    private let refusal = DriverError.badResponse(
        status: 422, body: StepExecutor.runnerEmptyRefusalPrefix + " (12 character(s) still there after 4 round(s))")

    private func answer(residual: String?, notDrawn: Bool, why: String? = nil, lines: [String] = []) -> StepExecutor.ClearResidualAnswer {
        StepExecutor.ClearResidualAnswer(residual: residual, notDrawn: notDrawn, why: why, snapshot: nil, drawnLines: lines)
    }

    private func body(_ r: MCPServer.EmptyRefusalResolution) -> String {
        guard case .refused(let e) = r, case DriverError.badResponse(_, let b) = e else { return "<\(r)>" }
        return b
    }

    /// 画面で確かめていない(fmAndVision が false)事実を言う
    func testUncheckedRefusalSaysItWasNotChecked() {
        let text = body(MCPServer.emptyRefusalResolution(refusal, answer: nil))
        XCTAssertTrue(text.hasPrefix(StepExecutor.runnerEmptyRefusalPrefix), text)
        XCTAssertTrue(text.contains("not checked against the screen"), text)
        XCTAssertTrue(text.contains("fmAndVision"), text)
    }

    func testNotDrawnResidualIsTreatedAsCleared() {
        guard case .cleared(let note) = MCPServer.emptyRefusalResolution(refusal, answer: answer(residual: "v", notDrawn: true)) else {
            return XCTFail("通らなかった")
        }
        XCTAssertTrue(note.contains("treated as cleared"), note)
    }

    func testDrawnTextStaysRedWithTheFact() {
        let text = body(MCPServer.emptyRefusalResolution(refusal, answer: answer(residual: "v", notDrawn: false, lines: ["bx"])))
        XCTAssertTrue(text.contains("could not empty the field"), text)
        XCTAssertTrue(text.contains("still shows text (OCR): \"bx\""), text)
    }

    func testUndeterminedStaysRedWithTheReason() {
        let text = body(MCPServer.emptyRefusalResolution(refusal, answer: answer(residual: "v", notDrawn: false, why: "OCR was unavailable")))
        XCTAssertTrue(text.contains("not checked against the screen: OCR was unavailable"), text)
    }

    func testOtherErrorsAreNotTouched() {
        let other = DriverError.badResponse(status: 422, body: "nothing has keyboard focus")
        guard case .notEmptyRefusal = MCPServer.emptyRefusalResolution(other, answer: nil) else { return XCTFail("触った") }
        XCTAssertFalse(MCPServer.isEmptyRefusal(other))
        XCTAssertTrue(MCPServer.isEmptyRefusal(refusal))
    }

    /// 絵で空と確かめて通した回は、value の読み返し(固定の案内文が残る)で「まだ残っている」と警告しない(同じ応答で食い違う)
    func testClearedByScreenCheckDoesNotWarnFromTheValueReadback() async throws {
        StepExecutor.clearResidualDrawnOverrideForTesting = { _ in (false, nil) }
        defer { StepExecutor.clearResidualDrawnOverrideForTesting = nil }
        let hint = "検索候補は次のとおりです"
        let field = ElementInfo(ref: 5, type: "textField", identifier: "field_search", label: "検索", value: hint,
                                placeholder: nil, enabled: true, frame: FTRect(x: 16, y: 100, width: 300, height: 48), depth: 2)
        let tree = SnapshotResponse(sessionBundleID: "com.ftester.e2ex", screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                    elements: [field], truncatedCount: 0)
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        driver.snapshotResponse = tree
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        driver.clearInputError = refusal
        let result = try await server.call(tool: "ft_clear_input", args: ["ref": 5, "fmAndVision": true])
        let text = try XCTUnwrap(result.first?["text"] as? String)
        XCTAssertTrue(text.contains("treated as cleared"), text)
        XCTAssertFalse(text.contains("still reads"), text)
    }

    /// ft_clear_input の catch が共有の確かめ(readClearResidual)を通る配線(通さないと DSL と判断が割れる)
    func testClearInputWiresTheSharedCheck() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/fleetest-mcp/MCPServer+ScreenTools.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("StepExecutor.readClearResidual("))
        XCTAssertTrue(src.contains("emptyRefusalResolution(error"))
    }
}
