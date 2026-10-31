// setTextRefusedHint(MCPServer+Dispatch.swift)は Android ブリッジ(InputInjector.java)のエラー
// メッセージの部分文字列(MCPServer.setTextRefusalMarker)に依存してヒントを出す。Java 側の文言が
// 変わると、この判定は二度と当たらなくなり黙って失敗する。Java 側は読み取りだけ(編集は対象外)。

import XCTest
@testable import fleetest_mcp

final class SetTextRefusedHintJavaSyncTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FleetestMCPTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
    }

    func testRefusalMarkerExistsInInputInjectorSource() throws {
        let path = repoRoot.appendingPathComponent(
            "AndroidRunner/src/com/example/ftbridge/InputInjector.java")
        let source = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(source.contains(MCPServer.setTextRefusalMarker),
                      "InputInjector.java の文言が変わった — setTextRefusedHint の"
                        + " message.contains(setTextRefusalMarker) が二度と当たらない")
    }

    func testDeliveryUnknownMarkerExistsInInputInjectorSource() throws {
        let path = repoRoot.appendingPathComponent(
            "AndroidRunner/src/com/example/ftbridge/InputInjector.java")
        let source = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(source.contains(MCPServer.setTextDeliveryUnknownMarker))
    }

    /// 届いたか分からない失敗(受理済み)に「ref なしで撃ち直せ」を付けない
    func testNoRetryAdviceWhenDeliveryUnknown() {
        XCTAssertEqual(MCPServer.setTextRefusedHint(
            tool: "ft_type", args: ["ref": 16],
            message: "cannot type into the field that was tapped (ACTION_SET_TEXT accepted 1 time);"
                + " whether the text reached the field is unknown"), "")
    }

    func testMaskedShortfallWarning() {
        XCTAssertNotNil(MCPServer.maskedShortfallWarning(held: 4, atLeast: 6))
        XCTAssertNil(MCPServer.maskedShortfallWarning(held: 6, atLeast: 6))
        XCTAssertNil(MCPServer.maskedShortfallWarning(held: 7, atLeast: 6))
    }
}
