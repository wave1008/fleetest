// アプリの UI フレームワークが不明の iOS で、主のドライバが XCUITest のとき、空打ちを撃つかは要素の本当のクラス名と祖先
// (`AppDriver.elementRenderer` = ランナーの `POST /renderer`)で決める。公開クラス(axClass)は UIKit の自前の要素を取り違える。
// 聞く意味の無い構成(Android・inapp-boost で typeDriver がある・アプリが判っている)では呼ばない

import XCTest
@testable import FTCore

final class EmptyDragRendererTests: XCTestCase {

    /// 地図のピン相当(公開クラスは UIAccessibilityElement)
    private func row() -> ElementInfo {
        ElementInfo(ref: 1, type: "button", identifier: "row_40", label: "行 40", value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 16, y: 300, width: 370, height: 56), depth: 3, axClass: "UIAccessibilityElement")
    }

    private func run(renderer: String?, isAndroid: Bool = false, releasesScrollTouch: Bool = true,
                     typeDriver: Bool = false, uiFramework: AppUIFramework? = nil) async -> (drags: Int, asked: Int) {
        let primary = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[], [], [row()]])
        primary.elementRendererAnswer = renderer
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver ? primary : nil,
                                    releasesScrollTouch: releasesScrollTouch, isAndroid: isAndroid, tunables: RunTunables(),
                                    uiFramework: uiFramework)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "row_40"), direction: "up", maxSwipes: 2)
        guard case .passed = await executor.execute(step).status else {
            XCTFail("スワイプ後の snapshot で見つかるので pass のはず"); return (-1, -1)
        }
        return (primary.dragCalls.count, primary.elementRendererCallCount)
    }

    func testUIKitCustomElementIsNotDragged() async {
        let r = await run(renderer: "uikitCustom")
        XCTAssertEqual(r.drags, 0)
        XCTAssertGreaterThanOrEqual(r.asked, 1)
    }

    func testFlutterElementIsDragged() async {
        let r = await run(renderer: "flutter")
        XCTAssertEqual(r.drags, 1)
    }

    func testNoAnswerFallsBackToTheAxClass() async {
        let r = await run(renderer: nil)
        XCTAssertEqual(r.drags, 1, "答えが無ければ今までどおり公開クラス(UIAccessibilityElement = 撃つ)")
    }

    func testTheRendererIsAskedOncePerTargetPerStep() async {
        let r = await run(renderer: "flutter")
        XCTAssertEqual(r.asked, 1, "見つけた木と撮り直した木で同じ対象を引き直しても、答えが出たら聞き直さない")
    }

    func testNeverAskedWhereItCannotMatter() async {
        let android = await run(renderer: "flutter", isAndroid: true, releasesScrollTouch: false)
        XCTAssertEqual(android.asked, 0, "Android")
        let androidReleasing = await run(renderer: "flutter", isAndroid: true, releasesScrollTouch: true)
        XCTAssertEqual(androidReleasing.asked, 0, "Android は releasesScrollTouch の設定に関わらず聞かない")
        let inAppBoost = await run(renderer: "flutter", typeDriver: true)
        XCTAssertEqual(inAppBoost.asked, 0, "typeDriver がある(inapp-boost の in-app が主)")
        let known = await run(renderer: "uikitCustom", uiFramework: .flutter)
        XCTAssertEqual(known.asked, 0, "アプリの答えがある")
        XCTAssertEqual(known.drags, 1, "アプリの答えが勝つ")
        let noDrag = await run(renderer: "flutter", releasesScrollTouch: false)
        XCTAssertEqual(noDrag.asked, 0, "空打ちの無い構成")
    }

    /// 同じステップの同じ対象は答えが出たら聞き直さない。答えが無かった(古い ref で断られた)ときは、ref が変わった撮り直しの木でだけ聞き直す
    func testPerStepCacheKeysOnTheTargetAndRetriesOnlyANewRef() async {
        let primary = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[row()]])
        let executor = StepExecutor(driver: primary, releasesScrollTouch: true, isAndroid: false, tunables: RunTunables())
        primary.elementRendererAnswer = nil
        _ = await executor.emptyDragRenderer(for: row())
        _ = await executor.emptyDragRenderer(for: row())
        XCTAssertEqual(primary.elementRendererCallCount, 1, "同じ ref の不明は聞き直さない")
        var moved = row(); moved.ref = 7
        primary.elementRendererAnswer = "flutter"
        let answer = await executor.emptyDragRenderer(for: moved)
        XCTAssertEqual(answer, "flutter")
        XCTAssertEqual(primary.elementRendererCallCount, 2, "ref が変わったら聞き直す")
        _ = await executor.emptyDragRenderer(for: row())
        XCTAssertEqual(primary.elementRendererCallCount, 2, "答えが出たら同じ対象には聞かない")
    }
}
