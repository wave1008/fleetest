// MCP の ref の指の操作も、DSL と同じ門(`TapTargetGeometry.otherLayerCoverSuspect`)が開いたときだけ
// `hitTest(ref:)` を聞き、false のときだけ撃たずに断る(true・答えなし・門が閉じる木は従来どおり撃つ)。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPOtherLayerHitTestTests: XCTestCase {

    private func element(_ ref: Int, _ type: String, _ id: String, _ frame: FTRect, depth: Int,
                         scrollable: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: id, value: nil, placeholder: nil,
                    enabled: true, frame: frame, depth: depth, scrollable: scrollable)
    }

    private func make(sameList: Bool, answer: HitTestAnswer) -> (MCPServer, FakeDriver) {
        let fake = FakeDriver()
        fake.foregroundBundleID = "com.example.app"
        fake.hitTestAnswer = answer
        let target = element(2, "button", "row_main_07", FTRect(x: 0, y: 400, width: 390, height: 60), depth: 2)
        let other = element(4, "button", "queue_row_03", FTRect(x: 0, y: 380, width: 390, height: 60), depth: 2)
        fake.snapshotResponse.elements = sameList
            ? [element(1, "other", "list", FTRect(x: 0, y: 0, width: 390, height: 844), depth: 1, scrollable: true), target, other]
            : [element(1, "other", "list_main", FTRect(x: 0, y: 0, width: 390, height: 844), depth: 1, scrollable: true),
               target,
               element(3, "other", "list_queue", FTRect(x: 0, y: 300, width: 390, height: 544), depth: 1, scrollable: true),
               other]
        let server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
        return (server, fake)
    }

    private func tap(_ server: MCPServer) async throws -> String {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        return try await server.call(tool: "ft_tap", args: ["ref": 2])
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    func testFalseRefusesAndSendsNothing() async throws {
        let (server, fake) = make(sameList: false, answer: .hittable(false))
        do {
            _ = try await tap(server)
            XCTFail("撃たずに断る")
        } catch {
            let message = "\(error)"
            XCTAssertTrue(message.contains("cannot be hit"), message)
            XCTAssertTrue(message.contains("Nothing was sent"), message)
            XCTAssertTrue(message.contains("queue_row_03"), message)
        }
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("tap(") }, "\(fake.calls)")
    }

    func testTrueStillFires() async throws {
        let (server, fake) = make(sameList: false, answer: .hittable(true))
        _ = try await tap(server)
        XCTAssertTrue(fake.calls.contains { $0.hasPrefix("tap(") }, "\(fake.calls)")
    }

    func testClosedGateStillFiresEvenIfThePlatformWouldSayFalse() async throws {
        let (server, fake) = make(sameList: true, answer: .hittable(false))
        _ = try await tap(server)
        XCTAssertTrue(fake.calls.contains { $0.hasPrefix("tap(") }, "\(fake.calls)")
    }
}
