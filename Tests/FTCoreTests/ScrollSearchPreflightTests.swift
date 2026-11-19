// 探索の入口の2つの判定: 払う前の断り(id を素のラベルで書いた)と scrollFrame の行 → 容器の切り替え

import XCTest
@testable import FTCore

final class ScrollSearchPreflightTests: XCTestCase {

    private func el(_ ref: Int, id: String?, label: String? = nil, x: Double = 0, y: Double, w: Double = 400, h: Double,
                    depth: Int = 1, scrollable: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: "other", identifier: id, label: label, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: depth, scrollable: scrollable)
    }

    func testRefusalFiresForAPlainLabelEqualToAnOnScreenId() {
        let elements = [el(1, id: "nav_search", label: "Search", y: 0, h: 50)]
        let text = LocatorResolver.idWrittenAsLabelRefusal(for: FlowLocator(label: "nav_search"), fallbacks: nil, in: elements)
        XCTAssertTrue(text?.hasPrefix("\"nav_search\" is read as a label; an element with that id is on screen — write #nav_search") == true, text ?? "nil")
        XCTAssertTrue(text?.contains("nothing was scrolled") == true, text ?? "nil")
    }

    func testRefusalStaysSilentOutsideThatShape() {
        let elements = [el(1, id: "nav_search", label: "Search", y: 0, h: 50)]
        // # で書いた・部分一致・型付き・||・ラベルが実在・id が画面に無い
        XCTAssertNil(LocatorResolver.idWrittenAsLabelRefusal(for: FlowLocator(id: "nav_search"), fallbacks: nil, in: elements))
        XCTAssertNil(LocatorResolver.idWrittenAsLabelRefusal(for: FlowLocator(label: "nav_search", labelMatch: .contains), fallbacks: nil, in: elements))
        XCTAssertNil(LocatorResolver.idWrittenAsLabelRefusal(for: FlowLocator(label: "nav_search", type: "other"), fallbacks: nil, in: elements))
        XCTAssertNil(LocatorResolver.idWrittenAsLabelRefusal(for: FlowLocator(label: "nav_search"),
                                                             fallbacks: [FlowLocator(label: "x")], in: elements))
        XCTAssertNil(LocatorResolver.idWrittenAsLabelRefusal(for: FlowLocator(label: "nav_search"), fallbacks: nil,
                                                             in: elements + [el(2, id: nil, label: "nav_search", y: 60, h: 50)]))
        XCTAssertNil(LocatorResolver.idWrittenAsLabelRefusal(for: FlowLocator(label: "nav_other"), fallbacks: nil, in: elements))
    }

    func testRefusalIsTheSearchResultMessage() {
        var result = StepExecutor.ScrollSearchResult(found: false, fallback: nil, viaXCUITest: false, hintJumps: 0, swipes: 0)
        result.immediateRefusal = "refused"
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(label: "x"))
        XCTAssertEqual(StepExecutor.scrollNotFoundMessage(step, result, defaultMaxSwipes: 8), "refused")
    }

    // MARK: scrollFrame の行 → 容器

    func testRowInsideAContainerGivesWayToTheNearestScrollableAncestor() {
        let elements = [el(1, id: nil, y: 300, h: 500, depth: 1, scrollable: true),
                        el(2, id: "nav_pager", y: 310, h: 60, depth: 2)]
        XCTAssertEqual(ScrollFrameResolution.enclosingScrollable(of: elements[1], in: elements, vertical: true)?.ref, 1)
        // 祖先でない小さな容器も行を収めるときも、木の祖先を選ぶ(最小を選ぶのは祖先が無いときだけ)
        let withOverlay = [el(1, id: nil, y: 300, h: 500, depth: 1, scrollable: true),
                           el(2, id: "nav_pager", y: 310, h: 60, depth: 2),
                           el(3, id: "overlay", y: 305, h: 100, depth: 1, scrollable: true)]
        XCTAssertEqual(ScrollFrameResolution.enclosingScrollable(of: withOverlay[1], in: withOverlay, vertical: true)?.ref, 1)
    }

    /// 申告の無い横の列(CMP iOS のタブ列)が縦の一覧の中にある形: 横に探すなら列のまま(縦の一覧へ切り替えない)。縦なら切り替える
    func testHorizontalRowInsideAVerticalListIsKeptWhenSearchingSideways() {
        let elements = [el(1, id: nil, y: 0, w: 402, h: 800, depth: 1, scrollable: true),
                        el(2, id: "stab_row", y: 198, w: 402, h: 48, depth: 2)]
        XCTAssertNil(ScrollFrameResolution.enclosingScrollable(of: elements[1], in: elements, vertical: false))
        XCTAssertEqual(ScrollFrameResolution.enclosingScrollable(of: elements[1], in: elements, vertical: true)?.ref, 1)
    }

    func testRowFallsBackToTheSmallestContainingScrollable() {
        // 兄弟として並ぶ(祖先でない)容器。大小2つのうち小さいほう
        let elements = [el(1, id: "nav_pager", y: 310, h: 60, depth: 1),
                        el(2, id: "big", y: 0, h: 800, depth: 1, scrollable: true),
                        el(3, id: "small", y: 300, h: 200, depth: 1, scrollable: true)]
        XCTAssertEqual(ScrollFrameResolution.enclosingScrollable(of: elements[0], in: elements, vertical: true)?.ref, 3)
    }

    func testEnclosingScrollableLeavesTheOtherShapesAlone() {
        // 自身が scrollable
        let scroller = [el(1, id: "list", y: 0, h: 800, scrollable: true)]
        XCTAssertNil(ScrollFrameResolution.enclosingScrollable(of: scroller[0], in: scroller, vertical: true))
        // 収める容器が無い(申告の無い Android の一覧)・枠が行を収めない
        let none = [el(1, id: "row", y: 0, h: 60)]
        XCTAssertNil(ScrollFrameResolution.enclosingScrollable(of: none[0], in: none, vertical: true))
        let partial = [el(1, id: nil, y: 0, h: 100, depth: 1, scrollable: true), el(2, id: "row", y: 80, h: 60, depth: 2)]
        XCTAssertNil(ScrollFrameResolution.enclosingScrollable(of: partial[1], in: partial, vertical: true))
        // 子孫に scrollable がある(`resolve` の領分)
        let withInner = [el(1, id: nil, y: 0, h: 800, depth: 1, scrollable: true), el(2, id: "wrap", y: 100, h: 400, depth: 2),
                         el(3, id: "inner", y: 110, h: 300, depth: 3, scrollable: true)]
        XCTAssertNil(ScrollFrameResolution.enclosingScrollable(of: withInner[1], in: withInner, vertical: true))
    }

    /// XCUITest の木の CMP(回帰で実測): 一覧 `#list_rows` は scrollable を申告せず、行が枠の外へはみ出す = 行ではなく一覧。
    /// 画面全体の容器へ切り替えると何も動かず赤になった
    func testUndeclaredListWhoseRowsOverflowIsNotTreatedAsARow() {
        let elements = [el(1, id: nil, y: 0, w: 402, h: 874, depth: 1, scrollable: true),
                        el(2, id: "list_rows", x: 16, y: 230, w: 370, h: 462, depth: 2),
                        el(3, id: "row_20", x: 16, y: 206, w: 370, h: 39, depth: 3),
                        el(4, id: "row_21", x: 16, y: 245, w: 370, h: 56, depth: 3),
                        el(5, id: "row_29", x: 16, y: 692, w: 370, h: 56, depth: 3)]
        XCTAssertNil(ScrollFrameResolution.enclosingScrollable(of: elements[1], in: elements, vertical: true))
    }

    /// 横のページャ `#pager_main`(子は枠の中)を横に探す: 画面全体の縦の容器(子は縦に並ぶ・向きの申告なし)へは切り替えない(DR-190 と同じ)
    func testHorizontalSearchDoesNotSwitchToAContainerThatOnlyStacksVertically() {
        let elements = [el(1, id: nil, y: 0, w: 402, h: 874, depth: 1, scrollable: true),
                        el(2, id: "btn_back", x: 4, y: 70, w: 48, h: 48, depth: 2),
                        el(3, id: "pager_main", x: 16, y: 142, w: 370, h: 240, depth: 2),
                        el(4, id: "txt_page_2", x: 32, y: 158, w: 61, h: 24, depth: 3),
                        el(5, id: "txt_pager_state", x: 16, y: 390, w: 60, h: 24, depth: 2),
                        el(6, id: "btn_pager_next", x: 16, y: 454, w: 114, h: 48, depth: 2)]
        XCTAssertNil(ScrollFrameResolution.enclosingScrollable(of: elements[2], in: elements, vertical: false))
    }

    /// 横へ動くと申告した容器の中の行を横に探す形は切り替える。縦の探索で、申告が横だけの容器へは切り替えない
    func testContainerMustMoveAlongTheSearchAxis() {
        func declared(_ ref: Int, x: Double, y: Double, w: Double, h: Double, actions: [String]) -> ElementInfo {
            ElementInfo(ref: ref, type: "other", identifier: nil, label: nil, value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: x, y: y, width: w, height: h), depth: 1, scrollable: true, scrollActions: actions)
        }
        let sideways = [declared(1, x: 0, y: 300, w: 402, h: 80, actions: ["left", "right"]),
                        el(2, id: "chip_01", x: 10, y: 310, w: 100, h: 60, depth: 2)]
        XCTAssertEqual(ScrollFrameResolution.enclosingScrollable(of: sideways[1], in: sideways, vertical: false)?.ref, 1)
        XCTAssertNil(ScrollFrameResolution.enclosingScrollable(of: sideways[1], in: sideways, vertical: true))
    }

    /// MCP の ft_scroll_to は注記の見分けの鍵で差し替えを拾う。文言を変えて鍵が外れると MCP だけ黙る
    func testSwitchNoteCarriesTheMarkerMCPLooksFor() {
        let container = el(1, id: nil, y: 0, h: 800, depth: 1, scrollable: true)
        let note = ScrollFrameResolution.enclosingScrollableNote(frame: "#nav_pager", container: container)
        XCTAssertTrue(note.contains(ScrollFrameResolution.enclosingScrollableMarker), note)
    }
}
