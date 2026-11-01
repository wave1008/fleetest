// アプリ自身のタップで出たシステムの権限アラートが前面でも、iOS の木はアプリの背面の木のまま変わらない(OI-46)。
// ft_snapshot は launch 系ツールの直後の1回しか前面のアラートを聞かなかったので、タップの後に背面の木を注記なしで返していた。
// 毎手の往復(約 0.6 秒)は払わず、操作の後なのに木が前と同じだった ft_snapshot だけ、同じ操作の後は1回だけ聞く。

import XCTest
import FTCore
@testable import fleetest_mcp

final class UnchangedTreeAlertProbeTests: XCTestCase {
    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: [ElementInfo(ref: 1, type: "button", identifier: "btn_request_photos",
                                   label: "写真", value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 16, y: 168, width: 370, height: 48), depth: 2)],
            truncatedCount: 0)
        driver.systemUICoveringResponse = SystemUICoveringResponse(covering: false)
    }

    private static let photosAlert = SystemAlertProbeResponse(
        present: true, title: "“E2E”が写真へのアクセスを求めています", buttons: ["許可しない", "許可"])

    private var alertProbes: Int { driver.calls.filter { $0 == "systemAlert" }.count }

    private func snapshotText() async throws -> String {
        try await server.call(tool: "ft_snapshot", args: [:]).compactMap { $0["text"] as? String }.joined()
    }

    /// 本命: タップの後に権限アラートが前面へ出ても木は同じ。次の ft_snapshot が前面のアラートを言い、背面の木を伏せる
    func testASnapshotAfterATapThatChangedNothingNamesTheFrontAlert() async throws {
        _ = try await snapshotText()
        _ = try await server.call(tool: "ft_tap", args: ["ref": 1])
        driver.scriptedSystemAlert = Self.photosAlert

        let text = try await snapshotText()

        XCTAssertTrue(text.contains("is in front of the app"), text)
        XCTAssertFalse(text.contains("btn_request_photos"), "背面の木を今の画面として返している: \(text)")
    }

    /// 同じ操作の後に木が同じまま ft_snapshot を重ねても、往復は1回(アラートが無いとき)
    func testAskedOnlyOncePerActionWhenNoAlertIsUp() async throws {
        _ = try await snapshotText()
        _ = try await server.call(tool: "ft_tap", args: ["ref": 1])
        let before = alertProbes

        _ = try await snapshotText()
        let afterFirst = alertProbes
        _ = try await snapshotText()
        _ = try await snapshotText()

        XCTAssertEqual(afterFirst - before, 1, "操作の後の最初の ft_snapshot で聞いていない: \(driver.calls)")
        XCTAssertEqual(alertProbes, afterFirst, "同じ操作の後に聞き直している: \(driver.calls)")
    }

    /// 対照: 操作が無ければ ft_snapshot を重ねても聞かない(毎手の往復を払わない)
    func testNoActionNoProbe() async throws {
        _ = try await snapshotText()
        let before = alertProbes
        _ = try await snapshotText()
        _ = try await snapshotText()
        XCTAssertEqual(alertProbes, before, "操作が無いのに聞いている: \(driver.calls)")
    }

    func testGateIsIOSOnlyAndNeedsAnOlderGeneration() {
        XCTAssertTrue(MCPServer.shouldProbeAfterUnchangedTree(
            isAndroid: false, lastGenerationActionCount: 1, sessionActionCount: 2, probedAtActionCount: nil))
        XCTAssertFalse(MCPServer.shouldProbeAfterUnchangedTree(
            isAndroid: true, lastGenerationActionCount: 1, sessionActionCount: 2, probedAtActionCount: nil))
        XCTAssertFalse(MCPServer.shouldProbeAfterUnchangedTree(
            isAndroid: false, lastGenerationActionCount: 2, sessionActionCount: 2, probedAtActionCount: nil))
        XCTAssertFalse(MCPServer.shouldProbeAfterUnchangedTree(
            isAndroid: false, lastGenerationActionCount: nil, sessionActionCount: 2, probedAtActionCount: nil))
        XCTAssertFalse(MCPServer.shouldProbeAfterUnchangedTree(
            isAndroid: false, lastGenerationActionCount: 1, sessionActionCount: 2, probedAtActionCount: 2))
    }
}
