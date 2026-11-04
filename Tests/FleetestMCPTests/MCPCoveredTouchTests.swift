// ref の指の操作(ft_tap・ft_long_press・ft_double_tap・ft_drag の fromRef)は、手前の操作可能な帯に中心を覆われた対象でも
// 中心(ref)をそのまま撃つ。MCP の木は常に塗り順なし扱い(`PaintOrder.isReal` が false)なので、手前の推測による
// 「見えている部分を押す / 薄ければ断る」は持たない。外側の一覧に切り取られた形(幾何で決まる)の断りは従来どおり。

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

    /// 見えている部分(700..740)が残る形でも、座標へずらさず ref で中心を撃つ
    func testTapShootsTheRefEvenWhenAVisiblePartRemains() async throws {
        let (server, fake) = make(tabTop: 740)
        let text = try await run(server, "ft_tap", ["ref": 1])
        XCTAssertTrue(fake.calls.contains { $0.hasPrefix("tap(ref:") }, "\(fake.calls)")
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("tap(x:") }, "\(fake.calls)")
        XCTAssertFalse(text.contains("was touched at"), text)
    }

    /// 見えている部分が床(8)に届かない形(残り 5)でも断らない
    func testTapDoesNotRefuseWhenTheUncoveredPartIsThin() async throws {
        let (server, fake) = make(tabTop: 705)
        let text = try await run(server, "ft_tap", ["ref": 1])
        XCTAssertTrue(fake.calls.contains { $0.hasPrefix("tap(ref:") }, "\(fake.calls)")
        XCTAssertFalse(text.contains("only 5 of the element is left uncovered"), text)
    }

    func testLongPressShootsTheRef() async throws {
        for tabTop in [740.0, 705.0] {
            let (server, fake) = make(tabTop: tabTop)
            _ = try await run(server, "ft_long_press", ["ref": 1])
            XCTAssertTrue(fake.calls.contains { $0.hasPrefix("press(ref:") }, "tabTop=\(tabTop): \(fake.calls)")
            XCTAssertFalse(fake.calls.contains { $0.hasPrefix("press(x:") }, "tabTop=\(tabTop): \(fake.calls)")
        }
    }

    /// ft_double_tap は座標だけで撃つ(ref の API が無い): 見えている部分でなく中心 (195, 750) を撃つ
    func testDoubleTapShootsTheCentre() async throws {
        for tabTop in [740.0, 705.0] {
            let (server, fake) = make(tabTop: tabTop)
            _ = try await run(server, "ft_double_tap", ["ref": 1])
            XCTAssertTrue(fake.calls.contains { $0.hasPrefix("doubleTap(x:195.0,y:750.0)") }, "tabTop=\(tabTop): \(fake.calls)")
        }
    }

    /// ft_drag の始点も見えている部分でなく中心 (195, 750)
    func testDragStartsFromTheCentre() async throws {
        for tabTop in [740.0, 705.0] {
            let (server, fake) = make(tabTop: tabTop)
            _ = try await run(server, "ft_drag", ["fromRef": 1, "dy": -100.0])
            XCTAssertTrue(fake.calls.contains { $0.hasPrefix("drag(195.0,750.0->") }, "tabTop=\(tabTop): \(fake.calls)")
        }
    }

    func testUncoveredTargetStillTapsByRef() async throws {
        let (server, fake) = make(tabTop: 820)   // 中心 750 は覆われない
        let text = try await run(server, "ft_tap", ["ref": 1])
        XCTAssertTrue(fake.calls.contains { $0.hasPrefix("tap(ref:") }, "\(fake.calls)")
        XCTAssertFalse(text.contains("not covered by it"), text)
    }

    /// 入れ子の外側の一覧に切り取られたカード(棚ごと一覧の上へ送り出された)への ref の操作は、DSL と同じ判定で撃たずに断る
    /// (撃つと画面の上端を叩いて一覧が先頭へ戻るだけで done だった。11周目の探索 ilocal F4)
    func testRefTouchesOnACardClippedByTheOuterListAreRefused() async throws {
        func el(_ ref: Int, _ type: String, id: String, _ f: FTRect, depth: Int, scroll: Bool = false) -> ElementInfo {
            var e = ElementInfo(ref: ref, type: type, identifier: id, label: id, value: nil, placeholder: nil,
                                enabled: true, frame: f, depth: depth)
            if scroll { e.scrollable = true }
            return e
        }
        for tool in ["ft_tap", "ft_long_press", "ft_double_tap"] {
            let fake = FakeDriver()
            fake.foregroundBundleID = "com.example.app"
            fake.snapshotResponse.elements = [
                el(1, "other", id: "list_nested", FTRect(x: 0, y: 157, width: 390, height: 600), depth: 1, scroll: true),
                el(2, "other", id: "shelf_2", FTRect(x: 0, y: -55, width: 390, height: 130), depth: 2, scroll: true),
                el(3, "button", id: "card_2_00", FTRect(x: 16, y: -50, width: 140, height: 120), depth: 3),
                el(4, "button", id: "card_2_01", FTRect(x: 164, y: -50, width: 140, height: 120), depth: 3),
                el(5, "button", id: "row_n_00", FTRect(x: 0, y: 400, width: 390, height: 48), depth: 2),
                el(6, "button", id: "row_n_01", FTRect(x: 0, y: 452, width: 390, height: 48), depth: 2),
            ]
            let server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
            server.settleWaitSeconds = 0
            do {
                _ = try await run(server, tool, ["ref": 3])
                XCTFail("\(tool): 撃たずに断る")
            } catch {
                XCTAssertTrue("\(error)".contains("outer scrolling list"), "\(tool): \(error)")
            }
            XCTAssertFalse(fake.calls.contains { $0.hasPrefix("tap(") || $0.hasPrefix("press(") || $0.hasPrefix("doubleTap(") },
                           "\(tool): \(fake.calls)")
        }
    }
}
