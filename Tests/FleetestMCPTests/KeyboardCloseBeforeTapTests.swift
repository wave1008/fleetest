// キーボードの下の対象への ref の tap は、副作用なしで閉じてから撃つ(DR-195。DSL の tap と同じ)。閉じられなければ従来どおり断る(DR-41)

import XCTest
import FTCore
@testable import fleetest_mcp

final class KeyboardCloseBeforeTapTests: XCTestCase {

    private let button = ElementInfo(ref: 1, type: "button", identifier: "btn_bottom", label: "下のボタン", value: nil,
                                      placeholder: nil, enabled: true, frame: FTRect(x: 16, y: 700, width: 370, height: 48), depth: 1)

    private func screen(keyboard: Bool) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example", screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                         elements: [button], truncatedCount: 0,
                         keyboardFrame: keyboard ? FTRect(x: 0, y: 538, width: 402, height: 336) : nil)
    }

    /// 閉じる手段はプラットフォームの hideKeyboard と同じ(ここではドライバが閉じる Android の形で経路を見る)
    func testClosesTheKeyboardThenTaps() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = screen(keyboard: true)
        let closed = screen(keyboard: false)
        driver.onHideKeyboard = { [driver] in driver.snapshotResponse = closed }
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        _ = try await server.call(tool: "ft_snapshot", args: ["platform": "android"])
        let content = try await server.call(tool: "ft_tap", args: ["ref": 1, "platform": "android"])
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        XCTAssertTrue(driver.calls.contains("hideKeyboard"), "\(driver.calls)")
        XCTAssertTrue(driver.calls.contains { $0.hasPrefix("tap(ref:") }, "\(driver.calls)")
        XCTAssertTrue(text.contains("closed first without sending Enter"), text)
        XCTAssertFalse(driver.calls.contains("pressEnter"), "Enter を送らない: \(driver.calls)")
    }

    func testStillRefusesWhenTheKeyboardStaysUp() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = screen(keyboard: true)
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        do {
            _ = try await server.call(tool: "ft_tap", args: ["ref": 1])
            XCTFail("閉じられないのに撃った: \(driver.calls)")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("refusing to act on"), error.localizedDescription)
        }
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("tap(ref:") }, "\(driver.calls)")
    }
}
