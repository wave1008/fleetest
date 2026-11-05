// in-app の openURL は、別のアプリを開く URL では対象アプリが前面から外れるのを待ってから返す
// (simctl openurl は開いた先が前に出る前に返り、次の tap が設定の下の対象アプリへ届いて緑・押されていた = 19〜20周目 ilocal F1)。
// 自分のスキームのディープリンクでは待たない(毎回上限を払わない)

import XCTest
@testable import FTBridgeClient

final class InAppOpenURLLeaveTests: XCTestCase {

    func testOnlyURLsOfAnotherAppWait() {
        let own: Set<String> = ["fte2eios"]
        XCTAssertTrue(InAppDriver.opensAnotherApp(url: "App-prefs:", ownSchemes: own))
        XCTAssertTrue(InAppDriver.opensAnotherApp(url: "https://example.com/", ownSchemes: own))
        XCTAssertFalse(InAppDriver.opensAnotherApp(url: "fte2eios://screen/lifecycle", ownSchemes: own))
        XCTAssertFalse(InAppDriver.opensAnotherApp(url: "FTE2EIOS://screen/lifecycle", ownSchemes: own), "スキームの大小を区別した")
        XCTAssertFalse(InAppDriver.opensAnotherApp(url: "https://example.com/", ownSchemes: nil), "スキームが分からないのに待つ")
        XCTAssertFalse(InAppDriver.opensAnotherApp(url: "not a url", ownSchemes: own))
    }

    /// 配線: 配送の後に、別のアプリを開くときだけ外れるのを待つ(simctl を撃つので openURL 全体は通せない = ソース走査)
    func testOpenURLWaitsForLeavingAfterDelivery() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FTBridgeClient/InAppDriver.swift"), encoding: .utf8)
        guard let start = source.range(of: "public func openURL(_ url: String, bundleID: String?) async throws {"),
              let end = source.range(of: "private func awaitLeavingForeground()", range: start.upperBound..<source.endIndex)
        else { return XCTFail("走査の範囲が見つからない") }
        let body = String(source[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("Self.opensAnotherApp(url: url, ownSchemes: BridgeClient.appURLSchemes(bundleID: target, target: simTarget))"))
        XCTAssertTrue(body.contains("await awaitLeavingForeground()"))
    }

    func testLeaveProbeTimeoutIsPinned() {
        XCTAssertEqual(InAppDriver.leaveProbeTimeout, 0.5)
    }
}
