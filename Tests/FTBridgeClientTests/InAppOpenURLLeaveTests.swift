// in-app の openURL は、別のアプリを開く URL では対象アプリが前面から外れるのを待ってから返す
// (simctl openurl は開いた先が前に出る前に返り、次の tap が設定の下の対象アプリへ届いて緑・押されていた = 19〜20周目 ilocal F1)。
// 自分のスキームのディープリンクでは待たない(毎回上限を払わない)

import XCTest
import FTCore
@testable import FTBridgeClient

final class InAppOpenURLLeaveTests: XCTestCase {

    func testOnlyURLsOfAnotherAppWait() {
        let own: Set<String> = ["fte2eios"]
        XCTAssertTrue(InAppDriver.mayOpenAnotherApp(url: "App-prefs:", ownSchemes: own))
        XCTAssertTrue(InAppDriver.mayOpenAnotherApp(url: "https://example.com/", ownSchemes: own))
        XCTAssertFalse(InAppDriver.mayOpenAnotherApp(url: "fte2eios://screen/lifecycle", ownSchemes: own))
        XCTAssertFalse(InAppDriver.mayOpenAnotherApp(url: "FTE2EIOS://screen/lifecycle", ownSchemes: own), "スキームの大小を区別した")
        // 実機はスキームが読めない = 待つ(待たずに返すと直後の tap が前面のアプリへ届いた。21周目 phys F1)
        XCTAssertTrue(InAppDriver.mayOpenAnotherApp(url: "https://example.com/", ownSchemes: nil), "スキームが分からないのに待たない")
        XCTAssertFalse(InAppDriver.mayOpenAnotherApp(url: "not a url", ownSchemes: own))
    }

    /// 配線: 配送の後に、別のアプリを開くときだけ外れるのを待つ(simctl を撃つので openURL 全体は通せない = ソース走査)
    func testOpenURLWaitsForLeavingAfterDelivery() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FTBridgeClient/InAppDriver.swift"), encoding: .utf8)
        guard let start = source.range(of: "public func openURL(_ url: String, bundleID: String?) async throws {"),
              let end = source.range(of: "private func awaitLeavingForeground()", range: start.upperBound..<source.endIndex)
        else { return XCTFail("走査の範囲が見つからない") }
        let body = String(source[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("Self.mayOpenAnotherApp(url: url, ownSchemes: ownSchemes)"))
        XCTAssertFalse(body.contains("if let simTarget"), "実機(simTarget が nil)で待ちを飛ばしている")
        XCTAssertTrue(body.contains("await awaitLeavingForeground()"))
    }

    /// 止めた後の照会が接続拒否以外(実機の iproxy の bridgeUnreachable)で落ちても、止めたアプリなら注入付きで起こす(33周目 phys)
    func testStoppedAppIsRelaunchedWhateverTheProbeFailure() {
        let ctx = DriverErrorContext(bridge: .iosXCUITest, physicalDevice: true, appFate: nil)
        let lost = DriverError.bridgeUnreachable(context: ctx, detail: "The network connection was lost.")
        let refused = DriverError.bridgeConnectionRefused(context: ctx, detail: "x")
        XCTAssertTrue(InAppDriver.relaunchesBeforeURL(probeError: lost, stoppedBySession: true))
        XCTAssertTrue(InAppDriver.relaunchesBeforeURL(probeError: refused, stoppedBySession: false))
        XCTAssertFalse(InAppDriver.relaunchesBeforeURL(probeError: lost, stoppedBySession: false),
                       "止めていない背面のアプリ(サスペンドで答えない)を起こし直した")
    }

    /// 配線: 照会の失敗で起こし直すかを上の関数で決める
    func testOpenURLConsultsTheRelaunchDecision() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FTBridgeClient/InAppDriver.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("if Self.relaunchesBeforeURL(probeError: error, stoppedBySession: stoppedBySession) {"))
    }

    func testLeaveProbeTimeoutIsPinned() {
        XCTAssertEqual(InAppDriver.leaveProbeTimeout, 0.5)
    }
}
