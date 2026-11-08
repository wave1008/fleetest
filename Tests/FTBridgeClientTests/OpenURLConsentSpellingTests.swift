import XCTest
@testable import FTBridgeClient
@testable import FTCore

/// 同意の確かめの1回の単位は URL スキームの綴り(大小を区別)。小文字の openURL が1回を使い切っても、
/// 大小違いの綴りでは確かめが走る。同じ綴りの2回目は走らない
final class OpenURLConsentSpellingTests: XCTestCase {
    private func seed(_ target: String) {
        BridgeClient.appListingCache.withLock {
            $0["\(target)#com.example.target"] = BridgeClient.AppListing(displayName: "Example", schemes: ["exampleapp"])
        }
    }

    private func sessionCount(_ stub: RecordingStubServer) -> Int {
        stub.paths.filter { $0 == "POST /session" }.count
    }

    func testDifferentSpellingChecksAgain() async throws {
        let stub = try RecordingStubServer()
        defer { stub.stop() }
        let target = "SPELL-\(UUID().uuidString)"
        seed(target)
        let client = BridgeClient(port: stub.port)
        await client.acknowledgeOpenURLConsent(bundleID: "com.example.target", target: target, url: "exampleapp://a")
        let first = sessionCount(stub)
        XCTAssertGreaterThan(first, 0, "1回目で確かめが走っていない")
        await client.acknowledgeOpenURLConsent(bundleID: "com.example.target", target: target, url: "EXAMPLEAPP://a")
        XCTAssertGreaterThan(sessionCount(stub), first, "大小違いの綴りで確かめが走らなかった")
    }

    func testSameSpellingDoesNotCheckAgain() async throws {
        let stub = try RecordingStubServer()
        defer { stub.stop() }
        let target = "SAME-\(UUID().uuidString)"
        seed(target)
        let client = BridgeClient(port: stub.port)
        await client.acknowledgeOpenURLConsent(bundleID: "com.example.target", target: target, url: "exampleapp://a")
        let first = sessionCount(stub)
        XCTAssertGreaterThan(first, 0)
        await client.acknowledgeOpenURLConsent(bundleID: "com.example.target", target: target, url: "exampleapp://b")
        XCTAssertEqual(sessionCount(stub), first, "同じ綴りの2回目で確かめ直した")
    }
}
