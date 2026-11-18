// id を素のラベルとして書いた外れの案内・失敗文の向きの例

import XCTest
@testable import FTCore

final class IdWrittenAsLabelHintTests: XCTestCase {

    private func el(_ ref: Int, id: String?, label: String?, type: String = "button") -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 0, y: Double(ref) * 60, width: 100, height: 50), depth: 1)
    }

    func testHintFiresOnlyForAPlainLabelEqualToAnId() {
        let elements = [el(1, id: "nav_collapse", label: "Collapse")]
        XCTAssertEqual(LocatorResolver.idWrittenAsLabelHint(for: FlowLocator(label: "nav_collapse"), in: elements),
                       "\"nav_collapse\" is read as a label; an element with that id is on screen — write #nav_collapse")
        // 既に # で書いた・型付き・部分一致・ラベルが実在する・id が違う、には出さない
        XCTAssertNil(LocatorResolver.idWrittenAsLabelHint(for: FlowLocator(id: "nav_collapse"), in: elements))
        XCTAssertNil(LocatorResolver.idWrittenAsLabelHint(for: FlowLocator(label: "nav_collapse", type: "button"), in: elements))
        XCTAssertNil(LocatorResolver.idWrittenAsLabelHint(for: FlowLocator(label: "nav_collapse", labelMatch: .contains), in: elements))
        XCTAssertNil(LocatorResolver.idWrittenAsLabelHint(for: FlowLocator(label: "nav_collapse"),
                                                          in: elements + [el(2, id: nil, label: "nav_collapse")]))
        XCTAssertNil(LocatorResolver.idWrittenAsLabelHint(for: FlowLocator(label: "nav"), in: elements))
    }

    func testScrollOffHintNamesBothDirections() {
        let container = ElementInfo(ref: 1, type: "scrollView", identifier: "list", label: nil, value: nil, placeholder: nil,
                                    enabled: true, frame: FTRect(x: 0, y: 0, width: 400, height: 800), depth: 1,
                                    scrollable: true, scrollActions: ["up", "down"])
        let snapshot = SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                        elements: [container, ElementInfo(ref: 2, type: "button", identifier: "row_9", label: nil, value: nil,
                                                                          placeholder: nil, enabled: true,
                                                                          frame: FTRect(x: 0, y: 780, width: 400, height: 48), depth: 2)],
                                        truncatedCount: 0)
        let hint = StepExecutor.scrollOffHint(FlowStep(action: "tap", locator: FlowLocator(id: "x")), in: snapshot)
        XCTAssertTrue(hint.contains("scroll: .down, or .up if it is above"), hint)
        XCTAssertFalse(hint.contains("scroll: .up)"), hint)
    }

    /// 向きを書かない探索(既定)でも、横の容器なら縦の逆向きを勧めず容器の軸を名指す
    func testDefaultDirectionSearchOnAHorizontalContainerNamesItsAxis() {
        var result = StepExecutor.ScrollSearchResult(found: false, fallback: nil, viaXCUITest: false,
                                                     hintJumps: 0, swipes: 2, stoppedUnmoving: true)
        result.scrollFrameOtherAxis = true
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "tab9"), maxSwipes: 3,
                            scrollFrame: FlowLocator(id: "stab_row"))
        let message = StepExecutor.scrollNotFoundMessage(step, result, defaultMaxSwipes: 8)
        XCTAssertTrue(message.contains("direction: .left / .right"), message)
        XCTAssertFalse(message.contains("direction: .up"), message)
    }
}
