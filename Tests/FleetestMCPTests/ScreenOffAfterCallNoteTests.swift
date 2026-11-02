// 呼び出しの最中に Android の画面が消灯すると、直前の tap は ok なのにアプリへ届いておらず、次の手の失敗文は消灯に触れない
// 。操作の後の確認 `screenOffAfterCallNote` が成功・失敗の両方の応答へ載ることを固定する。

import XCTest
@testable import fleetest_mcp

final class ScreenOffAfterCallNoteTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testTextNamesTheDeviceAndDoesNotClaimDelivery() {
        let text = MCPServer.screenOffAfterCallText(serial: "14141JEC204922")
        XCTAssertTrue(text.contains("14141JEC204922"))
        XCTAssertTrue(text.contains("may not have reached the app"), "届いたかは断定しない")
        XCTAssertFalse(text.contains("environment"), "環境要因という分類を置かない")
    }

    /// 成功(decorated)と失敗(catch の hint)の両方へ配線されていること。片方だけだと、失敗の応答だけ消灯を言わない
    func testNoteIsWiredIntoBothTheSuccessAndFailurePaths() throws {
        let source = try String(contentsOf: Self.root.appendingPathComponent(
            "Sources/fleetest-mcp/MCPServer+Dispatch.swift"), encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "screenOffAfterCallNote(tool: tool, args: resolved)").count - 1, 2,
                       "decorated と catch の hint の2箇所で呼ぶこと")
    }

    /// 端末を動かすツールだけ・差し替えドライバでは撃たない
    func testOnlyDeviceDrivingToolsAndNeverWithAFakeDriver() throws {
        let source = try String(contentsOf: Self.root.appendingPathComponent(
            "Sources/fleetest-mcp/MCPServer+Driver.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("guard makeDriver == nil, Self.toolEffects[tool] == .drivesDevice"))
    }
}
