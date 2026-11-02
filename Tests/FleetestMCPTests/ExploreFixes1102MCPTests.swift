// 2026-11-02 の探索の所見(sim F1・F2/F4・F5・F7・F3、se3 F1、emu F1、pixel F4)の塞ぎ

import XCTest
import FTCore
import FTTestSupport
@testable import fleetest_mcp

final class ExploreFixes1102MCPTests: XCTestCase {
    private func el(_ ref: Int, _ id: String?, _ type: String = "button", label: String? = nil,
                    x: Double = 16, y: Double, w: Double = 370, h: Double = 52, depth: Int = 2,
                    scrollable: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: x, y: y, width: w, height: h), depth: depth, scrollable: scrollable)
    }

    // MARK: F7 遷移中の古い ref

    /// 残った id が全部同じ量だけ動き、新しい id が同じ数以上出た形は、操作の後なら断る。短いスクロール(新しい id が数件)は通す
    func testTransitionShapeIsRefusedOnlyWhenArrivalsMatchTheShiftedSiblings() throws {
        let old = el(1, "nav_player", y: 595)
        let sibs: (Double) -> [ElementInfo] = { dx in
            (0..<4).map { self.el(10 + $0, "side_\($0)", x: 16 + dx, y: 100 + Double($0) * 60) }
        }
        let taken = [old] + sibs(0)
        let moved = el(2, "nav_player", x: 16 - 121, y: 595)
        let arrivals = (0..<4).map { el(30 + $0, "row_main_0\($0)", y: 100 + Double($0) * 60) }
        let transition = [moved] + sibs(-121) + arrivals
        XCTAssertEqual(RefGuard.retargetVerdict(target: old, found: moved, in: transition, taken: taken, ownActionSince: true),
                       .screenTransition(shifted: 4, arrivals: 4))
        // 操作を挟んでいなければ従来どおり
        XCTAssertEqual(RefGuard.retargetVerdict(target: old, found: moved, in: transition, taken: taken, ownActionSince: false),
                       .proceed)
        // 短いスクロール: 新しい id は1件だけ
        let scroll = [moved] + sibs(-121) + [arrivals[0]]
        XCTAssertEqual(RefGuard.retargetVerdict(target: old, found: moved, in: scroll, taken: taken, ownActionSince: true),
                       .proceed)
    }

    // MARK: F1 動いた先でも同じ警告を付ける(配線)

    func testMovedPathCarriesTheSameWarningsAsTheStillPath() throws {
        let source = try MCPServerSourceText.combined()
        let compact = source.components(separatedBy: .whitespacesAndNewlines).joined()
        XCTAssertTrue(compact.contains("return(found.ref,overlap+movedNote+"),
                      "動いた経路が overlap(画面外・覆い・貼り付く見出し・ヒットテスト)を付けていない")
    }

    // MARK: F2 / F4 帯の外の覆い

    func testRowUnderAnInnerBandIsSuspected() {
        let list = el(1, "list", "scrollView", x: 0, y: 0, w: 402, h: 874, depth: 1, scrollable: true)
        let band = el(2, "tab_media", y: 218, h: 48)
        let row = el(3, "post_10", x: 0, y: 209, w: 402, h: 56, depth: 3)
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        XCTAssertTrue(TapTargetGeometry.suspectedHiddenUnderChrome(row, in: [list, band, row], screen: screen),
                      "縁の帯の外のタブ帯の裏の行にも照会を払う")
        let clear = el(3, "post_10", x: 0, y: 400, w: 402, h: 56, depth: 3)
        XCTAssertFalse(TapTargetGeometry.suspectedHiddenUnderChrome(clear, in: [list, band, clear], screen: screen))
    }

    /// 隠れて描かれていないバーのボタン(画面の下端に接し、枠が背後の一覧の内側に残る)は照会を払う
    func testBarControlTouchingScreenEdgeOverAScrollerIsSuspected() {
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        let list = el(1, "list", "scrollView", x: 0, y: 0, w: 402, h: 874, depth: 1, scrollable: true)
        let bar = el(2, "btn_bottom_a", x: 16, y: 830, w: 74, h: 44, depth: 1)
        XCTAssertTrue(TapTargetGeometry.suspectedHiddenUnderChrome(bar, in: [list, bar], screen: screen))
        let inner = el(2, "btn_bottom_a", x: 16, y: 500, w: 74, h: 44, depth: 1)
        XCTAssertFalse(TapTargetGeometry.suspectedHiddenUnderChrome(inner, in: [list, inner], screen: screen),
                       "縁に接しない部品は聞かない")
        XCTAssertFalse(TapTargetGeometry.suspectedHiddenUnderChrome(bar, in: [bar], screen: screen),
                       "隣接する容器が無ければ聞かない")
    }

    /// 実アプリのコーパスで照会を払う操作部品の割合の上限。上げるときは増えた分を1件ずつ見る(毎タップ 72〜146ms)
    func testHiddenUnderChromeGateRateOnTheRealCorpus() throws {
        var fired = 0, total = 0
        for (_, snap) in try RealAppSnapshotCorpus.all() {
            let els = snap.elements.filter { TapTargetGeometry.interactiveTypes.contains($0.type) }
            fired += els.filter { TapTargetGeometry.suspectedHiddenUnderChrome($0, in: snap.elements, screen: snap.screen) }.count
            total += els.count
        }
        XCTAssertGreaterThan(total, 0)
        XCTAssertLessThanOrEqual(Double(fired) / Double(total), 0.06, "\(fired)/\(total)")
    }

    // MARK: F5 容器を見出しと呼ばない

    func testTheScrollContainerItselfIsNotAStickyHeader() {
        let list = el(1, "list_chat", "other", x: 0, y: 268, w: 402, h: 498, depth: 2, scrollable: true)
        let row = el(2, "msg_51", x: 0, y: 262, w: 402, h: 56, depth: 3)
        let others = (0..<4).map { el(10 + $0, "msg_\(52 + $0)", x: 0, y: 330 + Double($0) * 60, w: 402, h: 56, depth: 3) }
        XCTAssertNil(TapTargetGeometry.pinnedBandNote(for: row, in: [list, row] + others, operation: "touch"))
    }

    // MARK: F3 一部が見えている行は断言しない

    func testPartlyVisibleRowDoesNotSayAlmostCertainlyDidNothing() throws {
        let screen = FTRect(x: 0, y: 0, width: 874, height: 402)
        let part = el(1, "post_00", x: 62, y: 389, w: 750, h: 56)
        let text = try XCTUnwrap(TapTargetGeometry.offscreenAdvisory(for: part, screen: screen))
        XCTAssertFalse(text.contains("almost certainly"), text)
        XCTAssertTrue(text.contains("may have done nothing"), text)
        let gone = el(2, "post_x", x: 62, y: 500, w: 750, h: 56)
        XCTAssertTrue(try XCTUnwrap(TapTargetGeometry.offscreenAdvisory(for: gone, screen: screen)).contains("almost certainly"))
    }

    // MARK: se3 F1 キーボードを除いたピンチの領域

    func testPinchAreaStaysAboveTheKeyboard() {
        let screen = FTRect(x: 0, y: 0, width: 375, height: 667)
        let keyboard = FTRect(x: 0, y: 434, width: 375, height: 233)
        let withKeyboard = SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [], truncatedCount: 0,
                                            keyboardShown: true, keyboardFrame: keyboard)
        let picked = PinchRegion.area(in: withKeyboard)
        XCTAssertLessThanOrEqual(picked.region.y + picked.region.height, 434)
        let without = SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [], truncatedCount: 0)
        XCTAssertEqual(PinchRegion.area(in: without).region, screen)
    }

    // MARK: emu F1 横向きの全画面 IME

    func testSwipeNoteDoesNotClaimTheAreaAboveWhenTheKeyboardFillsTheScreen() {
        let screen = FTRect(x: 0, y: 0, width: 2400, height: 1080)
        let full = SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [], truncatedCount: 0,
                                    keyboardShown: true, keyboardFrame: FTRect(x: 142, y: 137, width: 2282, height: 943))
        XCTAssertTrue(MCPServer.keyboardSwipeAreaNote(full).contains("warning"))
        let low = SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 402, height: 874), elements: [],
                                   truncatedCount: 0, keyboardShown: true, keyboardFrame: FTRect(x: 0, y: 600, width: 402, height: 274))
        XCTAssertTrue(MCPServer.keyboardSwipeAreaNote(low).contains("area above it"))
    }

    // MARK: sim F9 隠れた対象を「画面にある」と言わない

    func testHiddenTargetIsNotReportedAsOnScreen() {
        let hidden = MCPServer.scrollToHeadline("#btn_top_action", swipes: 0, hiddenUnderChrome: true, underKeyboard: false)
        XCTAssertTrue(hidden.contains("NOT hittable"), hidden)
        XCTAssertFalse(hidden.contains("already on screen"), hidden)
        XCTAssertTrue(MCPServer.scrollToHeadline("#a", swipes: 0, hiddenUnderChrome: false, underKeyboard: false).contains("already on screen"))
    }
}
