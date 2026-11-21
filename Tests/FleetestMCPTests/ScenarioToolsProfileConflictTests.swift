import XCTest
@testable import fleetest_mcp

/// `MCPServer.profileConflict` — profile が port/serial/udid と併用されたら拒否し、platform はプロファイルにその OS が
/// あれば受ける(DR-212)。**args とプロファイルの OS だけを見る純粋関数を直接叩く**
final class ScenarioToolsProfileConflictTests: XCTestCase {

    func testNoProfileNeverConflicts() {
        XCTAssertNil(MCPServer.profileConflict([:], profilePlatforms: nil))
        XCTAssertNil(MCPServer.profileConflict(["platform": "ios", "port": 8100], profilePlatforms: nil))
    }

    func testProfileAloneDoesNotConflict() {
        XCTAssertNil(MCPServer.profileConflict(["profile": "ios"], profilePlatforms: ["ios"]))
    }

    func testPlatformTheProfileHasIsAccepted() {
        XCTAssertNil(MCPServer.profileConflict(["profile": "ios-run", "platform": "ios"], profilePlatforms: ["ios"]))
        XCTAssertNil(MCPServer.profileConflict(["profile": "mixed", "platform": "android"], profilePlatforms: ["ios", "android"]))
    }

    func testPlatformTheProfileLacksIsRefused() {
        let message = MCPServer.profileConflict(["profile": "ios-run", "platform": "android"], profilePlatforms: ["ios"])
        XCTAssertEqual(message, "platform \"android\" does not match profile \"ios-run\", whose devices are ios"
                       + " — drop platform (the profile picks the device)")
    }

    func testPlatformWithUnreadableProfileIsRefused() {
        XCTAssertNotNil(MCPServer.profileConflict(["profile": "missing", "platform": "ios"], profilePlatforms: nil))
    }

    func testProfileWithPortConflicts() {
        XCTAssertNotNil(MCPServer.profileConflict(["profile": "ios", "port": 8100], profilePlatforms: ["ios"]))
    }

    func testProfileWithSerialConflicts() {
        XCTAssertNotNil(MCPServer.profileConflict(["profile": "ios", "serial": "ABC123"], profilePlatforms: ["android"]))
    }

    func testProfileWithUDIDConflicts() {
        // foldingUDIDIntoPort が port へ畳んでも元の "udid" キーは args に残るので、ここでも拾えることを固定する
        XCTAssertNotNil(MCPServer.profileConflict(["profile": "ios", "udid": "0000-1111"], profilePlatforms: ["ios"]))
    }
}
