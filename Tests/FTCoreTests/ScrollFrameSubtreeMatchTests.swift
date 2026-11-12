// 明示した scrollFrame の部分木の外の一致は、その一覧の行として扱わない(`StepExecutor.matchInsideScrollFrame`)。
// witness: Google マップの経路詳細(計測2周とも)。シートの見出しの「中央線」が #details_cardlist の上に見えていて、
// 探索はそれを一覧の上に見切れた行と読み、一覧の中で指を下へ3回払ってシートを畳み、枠の外の見出しを「見つかった」と返した

import XCTest
@testable import FTCore

final class ScrollFrameSubtreeMatchTests: XCTestCase {

    /// 偽ドライバの画面(400x800)に合わせた位置関係(実測の木を縮めたもの: 見出し → 一覧が下に続く)
    private func el(_ ref: Int, _ type: String, _ label: String?, id: String? = nil, y: Double, height: Double = 20,
                    depth: Int, scrollable: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: y, width: 400, height: height), depth: depth, scrollable: scrollable)
    }

    /// 見出し(一覧の外・上)と一覧。`withTarget` なら一覧の中に「中央線」の行がある
    private func screen(withTarget: Bool, row: String = "赤羽駅") -> [ElementInfo] {
        var elements = [
            el(1, "other", nil, y: 0, height: 800, depth: 0),
            el(2, "clickable", "  埼京線", y: 400, height: 50, depth: 1),
            el(3, "staticText", "  中央線", y: 415, depth: 2),
            el(4, "collectionView", nil, id: "details_cardlist", y: 450, height: 350, depth: 1, scrollable: true),
            el(5, "staticText", row, y: 470, depth: 2),
        ]
        if withTarget { elements.append(el(6, "staticText", "中央線", y: 650, depth: 2)) }
        return elements
    }

    private func step() -> FlowStep {
        var step = FlowStep(action: "scrollTo", locator: FTSelector.parse("*中央線*").primary, direction: "up", maxSwipes: 4)
        step.scrollFrame = FlowLocator(id: "details_cardlist")
        return step
    }

    func testAMatchOutsideTheScrollFrameIsNotTreatedAsAClippedRow() async {
        let primary = FakeAppDriver(name: "primary", log: CallLog(),
                                    snapshotElements: [screen(withTarget: false), screen(withTarget: false, row: "新宿駅"),
                                                       screen(withTarget: true, row: "徒歩約2 分")])
        let outcome = await StepExecutor(driver: primary, isAndroid: true, tunables: RunTunables(),
                                         uiFramework: .androidView).execute(step())
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status) \(primary.log.entries)") }
        XCTAssertFalse(primary.swipeDirections.contains(.down),
                       "枠の外の見出しを見切れた行と読み、逆へ払った(シートを畳む): \(primary.swipeDirections)")
        XCTAssertFalse(primary.dragCalls.contains { $0.toY > $0.fromY }, "逆へ寄せた: \(primary.dragCalls)")
    }

    func testNarrowingPicksTheRowInsideAndLeavesOtherShapesAlone() {
        let snapshot = SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                        elements: screen(withTarget: true), truncatedCount: 0)
        let header = snapshot.elements[2]
        XCTAssertEqual(StepExecutor.matchInsideScrollFrame(step(), matched: header, in: snapshot)?.match?.0.ref, 6)
        XCTAssertNil(StepExecutor.matchInsideScrollFrame(step(), matched: snapshot.elements[5], in: snapshot),
                     "部分木の中の一致は絞らない")
        // 子を出さない容器(行が兄弟で並ぶ構成)は絞らない
        let flat = SnapshotResponse(sessionBundleID: nil, screen: snapshot.screen,
                                    elements: [el(4, "collectionView", nil, id: "details_cardlist", y: 450, height: 350,
                                                  depth: 1, scrollable: true),
                                               el(3, "staticText", "  中央線", y: 415, depth: 1)],
                                    truncatedCount: 0)
        XCTAssertNil(StepExecutor.matchInsideScrollFrame(step(), matched: flat.elements[1], in: flat))
    }
}
