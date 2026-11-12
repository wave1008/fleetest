// scrollFrame の解決(`ScrollFrameResolution.resolve`)。witness: Apple マップの経路一覧で `#RoutePlanningOverviewViewController` が
// pageIndicator(先頭・scroll なし・8,844 386x14)と scrollView(8,700 386x130・scroll)に当たり、先頭を払って何も動かなかった

import XCTest
@testable import FTCore

final class ScrollFrameResolutionTests: XCTestCase {

    private func el(_ ref: Int, _ type: String, id: String?, y: Double, height: Double,
                    scrollable: Bool? = nil, depth: Int = 1) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: 8, y: y, width: 386, height: height), depth: depth, scrollable: scrollable)
    }

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                         elements: elements, truncatedCount: 0)
    }

    private let pager = FlowLocator(id: "RoutePlanningOverviewViewController")

    /// 実測の木: 両方を包む外側のスクロール領域(#IOSRoutePlanningOverview 8,543 386x322)が pageIndicator と重なる
    private var routeList: [ElementInfo] {
        [el(1, "pageIndicator", id: "RoutePlanningOverviewViewController", y: 844, height: 14, depth: 2),
         el(2, "scrollView", id: "RoutePlanningOverviewViewController", y: 700, height: 130, scrollable: true, depth: 2),
         el(3, "scrollView", id: "IOSRoutePlanningOverview", y: 543, height: 322, scrollable: true, depth: 0)]
    }

    func testANonScrollingFirstMatchGivesWayToTheMatchThatScrolls() {
        XCTAssertEqual(ScrollFrameResolution.resolve(pager, in: snapshot(routeList))?.ref, 2)
    }

    func testOtherShapesKeepTheFirstMatch() {
        // 先頭も scroll(区別する材料が無い)
        let both = [el(1, "scrollView", id: "s", y: 62, height: 600, scrollable: true),
                    el(2, "scrollView", id: "s", y: 679, height: 166, scrollable: true)]
        XCTAssertEqual(ScrollFrameResolution.resolve(FlowLocator(id: "s"), in: snapshot(both))?.ref, 1)
        // scroll を申告できない木(全部 nil)
        let undeclared = routeList.map { e -> ElementInfo in var e = e; e.scrollable = nil; return e }
        XCTAssertEqual(ScrollFrameResolution.resolve(pager, in: snapshot(undeclared))?.ref, 1)
        // 先頭が中にスクロール領域を持つ枠(枠を指す自然な書き方 = 払えば中が動く)。木が平ら(枠の内側)でも子孫でも
        let wrapping = [el(1, "other", id: "w", y: 600, height: 250),
                        el(2, "scrollView", id: "w", y: 617, height: 213, scrollable: true)]
        XCTAssertEqual(ScrollFrameResolution.resolve(FlowLocator(id: "w"), in: snapshot(wrapping))?.ref, 1)
        let parent = [el(1, "other", id: "p", y: 600, height: 50),
                      el(4, "scrollView", id: nil, y: 640, height: 300, scrollable: true, depth: 2),
                      el(2, "scrollView", id: "p", y: 700, height: 100, scrollable: true)]
        XCTAssertEqual(ScrollFrameResolution.resolve(FlowLocator(id: "p"), in: snapshot(parent))?.ref, 1)
        // 添字を書いたらそのまま
        var first = pager
        first.index = 0
        XCTAssertEqual(ScrollFrameResolution.resolve(first, in: snapshot(routeList))?.ref, 1)
    }

    func testTheSwipeAreaAndTheNoteFollowTheScrollingMatch() {
        var step = FlowStep(action: "scroll", direction: "left")
        step.scrollFrame = pager
        let executor = StepExecutor(driver: FakeAppDriver(name: "d", log: CallLog()), isAndroid: false,
                                    tunables: RunTunables(), uiFramework: .uikit)
        let area = executor.scrollContainer(step: step, in: snapshot(routeList), vertical: false)
        XCTAssertEqual(area?.y, 700, "払う枠が pageIndicator のまま: \(String(describing: area))")
        XCTAssertNil(StepExecutor.scrollFrameNote(routeList[1], in: snapshot(routeList)))
        let note = StepExecutor.ambiguousScrollFrameNote(pager, picked: routeList[1], in: snapshot(routeList)) ?? ""
        XCTAssertTrue(note.contains("match [2] (the first that scrolls"), note)
    }
}
