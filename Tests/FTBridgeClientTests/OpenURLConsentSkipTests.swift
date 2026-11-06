import XCTest
@testable import FTBridgeClient
@testable import FTCore

/// 別のアプリ向けの URL では同意の確かめ(SpringBoard への張り替え・出現待ち・張り戻し)を撃たない(OI-179 ②)。
/// 自分のスキームでは従来どおり張り替える
final class OpenURLConsentSkipTests: XCTestCase {
    private func seed(_ target: String) {
        BridgeClient.appListingCache.withLock {
            $0["\(target)#com.example.target"] = BridgeClient.AppListing(displayName: "Example", schemes: ["exampleapp"])
        }
    }

    func testAnotherAppsURLDoesNotTouchSpringBoard() async throws {
        let stub = try RecordingStubServer()
        defer { stub.stop() }
        let target = "SKIP-\(UUID().uuidString)"
        seed(target)
        let client = BridgeClient(port: stub.port)
        await client.acknowledgeOpenURLConsent(bundleID: "com.example.target", target: target, url: "https://example.com")
        XCTAssertTrue(stub.paths.isEmpty, "別アプリ向けで確かめを撃った: \(stub.paths)")
    }

    func testOwnSchemeStillChecksTheConsent() async throws {
        let stub = try RecordingStubServer()
        defer { stub.stop() }
        let target = "OWN-\(UUID().uuidString)"
        seed(target)
        let client = BridgeClient(port: stub.port)
        await client.acknowledgeOpenURLConsent(bundleID: "com.example.target", target: target, url: "ExampleApp://screen/1")
        XCTAssertTrue(stub.paths.contains("POST /session"), "自分のスキームで確かめなかった: \(stub.paths)")
    }
}
