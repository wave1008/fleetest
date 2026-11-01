// 座標形の ft_tap / ft_double_tap / ft_long_press が**ソフトキーボードの中**を撃つときの警告。
// ref 形(RefGuard.keyboardWarning)は言うのに座標形は無警告で done と返し、実機 Pixel 3a では
// 欄にスペースが入った。拒否はしない(キーを押す意図があり得る)。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPKeyboardCoordinateWarningTests: XCTestCase {
    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 1080, height: 2220),
            elements: [ElementInfo(ref: 1, type: "textField", identifier: "field_single", label: nil,
                                   value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 44, y: 584, width: 992, height: 124), depth: 1,
                                   focused: true)],
            truncatedCount: 0, keyboardFrame: FTRect(x: 0, y: 1284, width: 1080, height: 936))
    }

    private func text(_ result: [[String: Any]]) -> String {
        result.compactMap { $0["text"] as? String }.joined()
    }

    func testTapInsideTheKeyboardWarnsButFires() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let body = text(try await server.call(tool: "ft_tap", args: ["x": 540.0, "y": 2000.0]))
        XCTAssertTrue(body.contains("is inside the soft keyboard (0,1284 1080x936)"), body)
        XCTAssertTrue(body.contains("presses a key, not the app behind it"), body)
        XCTAssertTrue(driver.calls.contains("tap(x:540.0,y:2000.0)"), "拒否はしない: \(driver.calls)")
    }

    func testDoubleTapAndLongPressInsideTheKeyboardWarnToo() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let doubleTap = text(try await server.call(tool: "ft_double_tap", args: ["x": 540.0, "y": 2000.0]))
        XCTAssertTrue(doubleTap.contains("is inside the soft keyboard"), doubleTap)
        let press = text(try await server.call(tool: "ft_long_press", args: ["x": 540.0, "y": 2000.0]))
        XCTAssertTrue(press.contains("is inside the soft keyboard"), press)
    }

    /// 直近の木にキーボードが無くても、その後に自分で操作していたら読み直して言う(ft_type の直後の座標の手が全部黙っていた)。
    /// 撃つ前の木で言う = 撃った後に閉じても言う。操作が無ければ読み直さない
    func testRereadsTheTreeAfterOwnActionBeforeFiring() async throws {
        let shown = driver.snapshotResponse.keyboardFrame
        driver.snapshotResponse.keyboardFrame = nil
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let quiet = text(try await server.call(tool: "ft_pinch", args: ["x": 540.0, "y": 2000.0, "scale": 2.0]))
        XCTAssertFalse(quiet.contains("soft keyboard"), quiet)
        driver.snapshotResponse.keyboardFrame = shown
        for (tool, extra) in [("ft_pinch", ["scale": 2.0]), ("ft_tap", [:]), ("ft_long_press", [:])] as [(String, [String: Any])] {
            let body = text(try await server.call(tool: tool, args: extra.merging(["x": 540.0, "y": 2000.0]) { a, _ in a }))
            XCTAssertTrue(body.contains("is inside the soft keyboard"), "\(tool): \(body)")
        }
    }

    /// type はキーボードの表示を待たずに返る: 読み直しの1回目にはまだ居ない。実測の形(出現を待ってから言う)
    func testWaitsForTheKeyboardRightAfterType() async throws {
        let shown = driver.snapshotResponse.keyboardFrame
        driver.snapshotResponse.keyboardFrame = nil
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        _ = try await server.call(tool: "ft_type", args: ["text": "ab", "ref": 1])
        var reads = 0
        let fake = driver!
        driver.onSnapshot = {
            reads += 1
            if reads >= 2 { fake.snapshotResponse.keyboardFrame = shown }
        }
        let body = text(try await server.call(tool: "ft_pinch", args: ["x": 540.0, "y": 2000.0, "scale": 2.0]))
        XCTAssertTrue(body.contains("is inside the soft keyboard"), body)
    }

    /// 陰性: キーボードの外・キーボードが無い木では黙る
    func testStaysSilentOutsideTheKeyboardAndWithoutOne() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let above = text(try await server.call(tool: "ft_tap", args: ["x": 540.0, "y": 600.0]))
        XCTAssertFalse(above.contains("soft keyboard"), above)

        driver.snapshotResponse.keyboardFrame = nil
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let noKeyboard = text(try await server.call(tool: "ft_tap", args: ["x": 540.0, "y": 2000.0]))
        XCTAssertFalse(noKeyboard.contains("soft keyboard"), noKeyboard)
    }
}
