// ref の指の操作(ft_tap・ft_long_press・ft_double_tap・ft_drag の fromRef)は、手前の操作可能な帯に中心を覆われた対象を
// DSL と同じ判定 `TapTargetGeometry.coveredTouch` で扱う: 覆われていない見えている部分を押す / 薄ければ撃たずに断る。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPCoveredTouchTests: XCTestCase {

    private func element(_ ref: Int, id: String, frame: FTRect, type: String = "button") -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: id, value: nil, placeholder: nil,
                    enabled: true, frame: frame, depth: 2)
    }

    /// 対象 y=700..800(中心 750)。タブ列が tabTop から下を覆う(木で対象より後ろ = 手前)
    private func make(tabTop: Double) -> (MCPServer, FakeDriver) {
        let fake = FakeDriver()
        fake.foregroundBundleID = "com.example.app"
        fake.snapshotResponse.elements = [
            element(1, id: "btn_submit", frame: FTRect(x: 20, y: 700, width: 350, height: 100)),
            element(2, id: "tab_home", frame: FTRect(x: 0, y: tabTop, width: 390, height: 844 - tabTop)),
        ]
        let server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
        return (server, fake)
    }

    private func run(_ server: MCPServer, _ tool: String, _ args: [String: Any]) async throws -> String {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        return try await server.call(tool: tool, args: args)
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    func testTapPressesTheUncoveredPart() async throws {
        let (server, fake) = make(tabTop: 740)   // 見えているのは 700..740 → 中心 (195, 720)
        let text = try await run(server, "ft_tap", ["ref": 1])
        XCTAssertTrue(fake.calls.contains { $0.hasPrefix("tap(x:195.0,y:720.0)") }, "\(fake.calls)")
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("tap(ref:") }, "\(fake.calls)")
        XCTAssertTrue(text.contains("is covered by") && text.contains("(195, 720)"), text)
    }

    func testTapRefusesWhenTheUncoveredPartIsThin() async throws {
        let (server, fake) = make(tabTop: 705)   // 残り 5 < 床 8
        do {
            _ = try await run(server, "ft_tap", ["ref": 1])
            XCTFail("撃たずに断る")
        } catch {
            let message = "\(error)"
            XCTAssertTrue(message.contains("only 5 of the element is left uncovered"), message)
            XCTAssertTrue(message.contains("Nothing was sent"), message)
        }
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("tap(") }, "\(fake.calls)")
    }

    func testLongPressPressesTheUncoveredPart() async throws {
        let (server, fake) = make(tabTop: 740)
        _ = try await run(server, "ft_long_press", ["ref": 1])
        XCTAssertTrue(fake.calls.contains { $0.hasPrefix("press(x:195.0,y:720.0") }, "\(fake.calls)")
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("press(ref:") }, "\(fake.calls)")
    }

    func testLongPressRefusesWhenThin() async throws {
        let (server, fake) = make(tabTop: 705)
        do { _ = try await run(server, "ft_long_press", ["ref": 1]); XCTFail("断る") } catch {}
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("press(") }, "\(fake.calls)")
    }

    func testDoubleTapUsesTheUncoveredPartAndRefusesWhenThin() async throws {
        let (server, fake) = make(tabTop: 740)
        _ = try await run(server, "ft_double_tap", ["ref": 1])
        XCTAssertTrue(fake.calls.contains { $0.hasPrefix("doubleTap(x:195.0,y:720.0)") }, "\(fake.calls)")
        let (thinServer, thinFake) = make(tabTop: 705)
        do { _ = try await run(thinServer, "ft_double_tap", ["ref": 1]); XCTFail("断る") } catch {}
        XCTAssertFalse(thinFake.calls.contains { $0.hasPrefix("doubleTap(") }, "\(thinFake.calls)")
    }

    func testDragStartsFromTheUncoveredPartAndRefusesWhenThin() async throws {
        let (server, fake) = make(tabTop: 740)
        _ = try await run(server, "ft_drag", ["fromRef": 1, "dy": -100.0])
        XCTAssertTrue(fake.calls.contains { $0.hasPrefix("drag(195.0,720.0->") }, "\(fake.calls)")
        let (thinServer, thinFake) = make(tabTop: 705)
        do { _ = try await run(thinServer, "ft_drag", ["fromRef": 1, "dy": -100.0]); XCTFail("断る") } catch {}
        XCTAssertFalse(thinFake.calls.contains { $0.hasPrefix("drag(") }, "\(thinFake.calls)")
    }

    func testUncoveredTargetStillTapsByRef() async throws {
        let (server, fake) = make(tabTop: 820)   // 中心 750 は覆われない
        let text = try await run(server, "ft_tap", ["ref": 1])
        XCTAssertTrue(fake.calls.contains { $0.hasPrefix("tap(ref:") }, "\(fake.calls)")
        XCTAssertFalse(text.contains("not covered by it"), text)
    }
}
