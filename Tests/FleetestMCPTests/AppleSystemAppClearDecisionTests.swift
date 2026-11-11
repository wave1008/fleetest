import XCTest
@testable import fleetest_mcp

/// iOS の com.apple.* の ft_clear_app_data: Simulator だけ消す・実機と宛先不明と SpringBoard は断る・Android は対象外
final class AppleSystemAppClearDecisionTests: XCTestCase {
    func testSimulatorAppleAppIsWiped() {
        XCTAssertEqual(MCPServer.appleSystemAppDecision(bundleID: "com.apple.Maps", isAndroid: false, isPhysical: false),
                       .wipeOnSimulator)
    }

    func testPhysicalAndUnknownTargetsAreRefused() {
        for physical in [true, nil] as [Bool?] {
            let decision = MCPServer.appleSystemAppDecision(bundleID: "com.apple.Maps", isAndroid: false, isPhysical: physical)
            guard case .refuse(let text) = decision else { return XCTFail("断らなかった: \(String(describing: physical))") }
            XCTAssertTrue(text.contains("Apple system app"), text)
        }
    }

    func testSpringBoardIsRefusedEvenOnASimulator() {
        guard case .refuse = MCPServer.appleSystemAppDecision(
            bundleID: MCPServer.springboardBundleID, isAndroid: false, isPhysical: false) else {
            return XCTFail("SpringBoard を断らなかった")
        }
    }

    func testNonAppleAndAndroidAreNotApplicable() {
        XCTAssertEqual(MCPServer.appleSystemAppDecision(bundleID: "com.example.app", isAndroid: false, isPhysical: false), .notApple)
        XCTAssertEqual(MCPServer.appleSystemAppDecision(bundleID: "com.apple.android.music", isAndroid: true, isPhysical: nil), .notApple)
    }
}
