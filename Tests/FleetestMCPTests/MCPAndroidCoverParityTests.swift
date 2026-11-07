// MCP の Android も DSL と同じく、木のアプリの UI フレームワークで塗り順が本物かを決め、覆いの判定(`coveredTouch`)を通す。
// OI-196: 全開のシートの裏の行 #row_main_05 への ft_batch の tap と ft_tap が、手前のキューの行 #queue_row_14 を押して ok(3/3)。
// DSL は 36周目の直し(v129 の clickable)で撃つ前に断るが、MCP は Android のフレームワークを持たず `PaintOrder.isReal` が false だった

import XCTest
@testable import FTCore
@testable import fleetest_mcp

final class MCPAndroidCoverParityTests: XCTestCase {
    private let android: [String: Any] = ["platform": "android"]

    /// AndroidClickableCoverTests と同じ形(シートの押せる行が裏の行を丸ごと覆う)
    private func sheetTree() -> SnapshotResponse {
        let elements = [
            ElementInfo(ref: 1, type: "collectionView", identifier: "list_main", label: nil, value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 0, y: 200, width: 1280, height: 2400), depth: 1, scrollable: true, z: 1),
            ElementInfo(ref: 2, type: "staticText", identifier: "row_main_05", label: "本文 05", value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 0, y: 1326, width: 1280, height: 168), depth: 2, z: 2, clickable: true),
            ElementInfo(ref: 3, type: "other", identifier: "player_sheet", label: nil, value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 0, y: 486, width: 1280, height: 2298), depth: 1, z: 3),
            ElementInfo(ref: 4, type: "staticText", identifier: "queue_row_14", label: "キュー 14", value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 0, y: 1261, width: 1280, height: 300), depth: 2, z: 4, clickable: true),
        ]
        return SnapshotResponse(sessionBundleID: "com.example.app", screen: FTRect(x: 0, y: 0, width: 1280, height: 2856),
                                elements: elements, truncatedCount: 0)
    }

    private func server(_ driver: FakeDriver, framework: AppUIFramework?) -> MCPServer {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        server.bridges[MCPServer.sessionKey(android)] = "android"
        server.androidUIFrameworkLookup = { bundleID, _ in bundleID == "com.example.app" ? framework : nil }
        return server
    }

    private func androidDriver() -> FakeDriver {
        let driver = FakeDriver()
        driver.answers = .android
        driver.foregroundBundleID = "com.example.app"
        driver.snapshotResponse = sheetTree()
        return driver
    }

    func testRefTouchUnderAPressableCoverIsRefusedOnlyWhenPaintOrderIsReal() {
        let tree = sheetTree()
        let target = tree.elements[1]
        guard case .refuse(let message) = MCPServer.coveredRefTouch(target, in: tree, scale: 3, ref: 2, operation: "tap",
                                                                    paintOrderIsReal: true) else {
            return XCTFail("塗り順が本物の木で、覆われた行を撃とうとした")
        }
        XCTAssertTrue(message.contains("queue_row_14"), message)
        guard case .none = MCPServer.coveredRefTouch(target, in: tree, scale: 3, ref: 2, operation: "tap",
                                                    paintOrderIsReal: false) else {
            return XCTFail("塗り順の無い木で手前を推測した")
        }
    }

    func testPaintOrderFollowsTheAndroidFrameworkOfTheTreesApp() {
        let driver = androidDriver()
        XCTAssertTrue(server(driver, framework: .androidView).refTreePaintOrderIsReal(sheetTree(), driver: driver, args: android))
        XCTAssertFalse(server(driver, framework: .flutter).refTreePaintOrderIsReal(sheetTree(), driver: driver, args: android),
                       "自前描画の z を塗り順と読んだ")
        XCTAssertFalse(server(driver, framework: nil).refTreePaintOrderIsReal(sheetTree(), driver: driver, args: android),
                       "フレームワークが分からないのに塗り順を推測した")
    }

    func testBatchTapUnderTheSheetIsRefusedLikeTheDSL() async throws {
        let driver = androidDriver()
        let server = server(driver, framework: .androidView)
        _ = try await server.call(tool: "ft_launch", args: android.merging(["bundleId": "com.example.app"]) { $1 })
        do {
            _ = try await server.call(tool: "ft_batch", args: android.merging(["steps": "tap '#row_main_05'"]) { $1 })
            XCTFail("覆いの下の行への tap が通った: \(driver.calls)")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("covered by #queue_row_14"), error.localizedDescription)
        }
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("tap(") }, "覆いの下の行へ撃った: \(driver.calls)")
    }

    func testRefTapUnderTheSheetIsRefused() async throws {
        let driver = androidDriver()
        let server = server(driver, framework: .androidView)
        _ = try await server.call(tool: "ft_launch", args: android.merging(["bundleId": "com.example.app"]) { $1 })
        _ = try await server.call(tool: "ft_snapshot", args: android)
        let ref = try XCTUnwrap(server.lastSnapshots[MCPServer.sessionKey(android)]?.elements
            .first { $0.identifier == "row_main_05" }?.ref)
        do {
            _ = try await server.call(tool: "ft_tap", args: android.merging(["ref": ref]) { $1 })
            XCTFail("覆いの下の行への ft_tap が通った: \(driver.calls)")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("queue_row_14"), error.localizedDescription)
        }
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("tap(") }, "\(driver.calls)")
    }
}
