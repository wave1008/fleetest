// 探索所見(2026-11-01)の文言: 届いたか不明の手の後に「Call again」を最初の対処にしない・接続の失敗に Enter を勧めない。

import XCTest
import FTCore
@testable import fleetest_mcp

final class ExploreFindingsRound2WordingTests: XCTestCase {
    private let context = DriverErrorContext(bridge: .iosXCUITest, physicalDevice: true)

    func testDeliveryUnknownTunnelMessageDoesNotLeadWithCallAgain() {
        let text = MCPServer.connectionLostMessage(connection: "port 8154", running: [], bridge: "xcuitest",
                                                   udid: "PHYS", tunnelOnly: true, deliveryUnknown: true)
        XCTAssertFalse(text.contains("Call again"), text)
        XCTAssertTrue(text.contains("ft_snapshot"), text)
    }

    func testRefusedTunnelMessageStillSaysCallAgain() {
        let text = MCPServer.connectionLostMessage(connection: "port 8154", running: [], bridge: "xcuitest",
                                                   udid: "PHYS", tunnelOnly: true)
        XCTAssertTrue(text.contains("Call again"), text)
    }

    func testHideKeyboardNeverSuggestsEnterForConnectionFailures() {
        XCTAssertFalse(MCPServer.hideKeyboardFailureIsNotAboutTheKeyboard(nil))
        XCTAssertTrue(MCPServer.hideKeyboardFailureIsNotAboutTheKeyboard(.deliveryUnknown(context: context, detail: "x")))
        XCTAssertFalse(MCPServer.hideKeyboardFailureIsNotAboutTheKeyboard(.badResponse(status: 500, body: "x")))
    }
}
