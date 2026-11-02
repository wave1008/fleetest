// 失敗した ft_scroll_to が画面を動かした事実を下書きに残す / 短縮形の呼び名が耐久性に合う

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPDraftScrollAndDurabilityNoteTests: XCTestCase {

    func testShortFormNamesTheRightKind() throws {
        XCTAssertNil(DraftNotes.selectorDurabilityShort(.stable))
        XCTAssertTrue(try XCTUnwrap(DraftNotes.selectorDurabilityShort(.indexed)).contains("index-based"))
        let relative = try XCTUnwrap(DraftNotes.selectorDurabilityShort(.relative))
        XCTAssertTrue(relative.contains("relative"))
        XCTAssertFalse(relative.contains("index-based"), relative)
    }

    /// 下書きの短縮形は耐久性ごとの呼び名・鍵を通る(固定の「index-based」へ戻すと落ちる)
    func testDraftUsesDurabilityAwareShortForm() throws {
        let source = try String(contentsOfFile: Self.path("Sources/fleetest-mcp/MCPServer+Draft.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("DraftNotes.selectorDurabilityShort(durability)"))
        XCTAssertFalse(source.contains("short: \"index-based selector (see the first note)\""))
    }

    /// 失敗の経路が、スワイプを撃った探索を下書きへ残す配線
    func testFailedScrollToRecordsATodoWhenItSwiped() throws {
        let source = try String(contentsOfFile: Self.path("Sources/fleetest-mcp/MCPServer+Snapshot.swift"), encoding: .utf8)
        let failure = try XCTUnwrap(source.range(of: "guard StepExecutor.isSuccess(outcome.status) else {"))
        let recorded = try XCTUnwrap(source.range(of: "failedScrollTodo(selector: selectorText, swipes: swipes)"))
        XCTAssertLessThan(failure.lowerBound, recorded.lowerBound)
    }

    func testFailedScrollTodoReachesTheDraft() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example", screen: FTRect(x: 0, y: 0, width: 360, height: 808),
            elements: [ElementInfo(ref: 1, type: "Button", identifier: "ok", label: "OK", value: nil,
                                   placeholder: nil, enabled: true,
                                   frame: FTRect(x: 10, y: 10, width: 100, height: 40), depth: 1)],
            truncatedCount: 0)
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example"])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        var entry = InteractionLog.Entry(step: nil, unresolved: nil, summary: "scrollTo \"X\" (did not reach it)")
        entry.todoNote = MCPServer.failedScrollTodo(selector: "X", swipes: 3)
        server.recordAction(entry, args: [:])
        _ = try await server.call(tool: "ft_tap", args: ["ref": 1])
        let content = try await server.call(tool: "ft_draft_scenario", args: [:])
        let draft = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(draft.contains("did not reach the element after 3 swipe(s)"), draft)
    }

    /// OI-129 (sim F9): 覆う相手が居ない「描かれていないだけ」の要素でも、プラットフォームが hittable でないと答えたら
    /// 「already on screen」と言わない(ゲートを通らない直接の問い合わせ)
    func testScrollToDoesNotSayOnScreenWhenThePlatformReportsNotHittable() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        driver.hitTestAnswer = .hittable(false)
        let content = try await server.call(tool: "ft_scroll_to", args: ["selector": "#login_btn"])
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        XCTAssertFalse(text.contains("was already on screen"), text)
        XCTAssertTrue(text.contains("NOT hittable"), text)
    }

    /// 答えられない(既定)・hittable なら従来どおり
    func testScrollToKeepsTheOnScreenHeadlineWhenHittable() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        driver.hitTestAnswer = .hittable(true)
        let content = try await server.call(tool: "ft_scroll_to", args: ["selector": "#login_btn"])
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        XCTAssertTrue(text.contains("was already on screen"), text)
    }

    private static func path(_ relative: String) -> String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(relative).path
    }
}
