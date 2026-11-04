// 塗り順の無い iOS の木で「別の層に覆われているかもしれない」対象を拾う門(`otherLayerCoverSuspect`)と、
// それを使う DSL の tap の配線(`hitTest(query:)` が false のときだけ撃たずに断る)の固定。
import XCTest
@testable import FTCore

final class OtherLayerOcclusionTests: XCTestCase {
    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    private func element(_ ref: Int, _ type: String, _ id: String, _ frame: FTRect, depth: Int,
                         scrollable: Bool? = nil, z: Int? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: id, value: nil, placeholder: nil,
                    enabled: true, frame: frame, depth: depth, scrollable: scrollable, z: z)
    }

    /// 半分のシート: 背面の一覧 A の行(対象)の中心を、シートの一覧 B の行が覆う
    private func sheetTree(zTarget: Int? = nil, zOther: Int? = nil, sameList: Bool = false) -> [ElementInfo] {
        let target = element(2, "button", "row_main_07", FTRect(x: 0, y: 400, width: 402, height: 60), depth: 2,
                             z: zTarget)
        let other = element(4, "button", "queue_row_03", FTRect(x: 0, y: 380, width: 402, height: 60),
                            depth: 2, z: zOther)
        if sameList {
            return [element(1, "other", "list", FTRect(x: 0, y: 0, width: 402, height: 874), depth: 1, scrollable: true),
                    target, other]
        }
        return [element(1, "other", "list_main", FTRect(x: 0, y: 0, width: 402, height: 874), depth: 1, scrollable: true),
                target,
                element(3, "other", "list_queue", FTRect(x: 0, y: 300, width: 402, height: 574), depth: 1, scrollable: true),
                other]
    }

    private func suspect(_ tree: [ElementInfo], target ref: Int = 2) -> ElementInfo? {
        let target = tree.first { $0.ref == ref }!
        return TapTargetGeometry.otherLayerCoverSuspect(target, in: tree, screen: screen)
    }

    func testSheetShapeNamesTheOtherLayersRow() {
        XCTAssertEqual(suspect(sheetTree())?.identifier, "queue_row_03")
    }

    func testOverlapInsideTheSameScrollContainerIsNotSuspected() {
        XCTAssertNil(suspect(sheetTree(sameList: true)))
    }

    func testAnyPaintOrderInTheTreeClosesTheGate() {
        XCTAssertNil(suspect(sheetTree(zTarget: 1, zOther: 2)))
        XCTAssertNil(suspect(sheetTree(zOther: 2)), "片方にだけ z があっても全か無かでない木は対象外")
    }

    func testLineageIsNotSuspected() {
        // 対象の祖先(行を包む別の押せる要素)・子孫は覆いではない
        let parent = element(1, "button", "card", FTRect(x: 0, y: 380, width: 402, height: 200), depth: 1, scrollable: nil)
        let target = element(2, "button", "inner", FTRect(x: 20, y: 400, width: 100, height: 60), depth: 2)
        let child = element(3, "button", "inner_child", FTRect(x: 30, y: 410, width: 50, height: 40), depth: 3)
        let tree = [parent, target, child]
        XCTAssertNil(TapTargetGeometry.otherLayerCoverSuspect(target, in: tree, screen: screen))
    }

    func testAnOtherThatWrapsTheTargetWholeIsNotSuspected() {
        // 別の容器の中の大きな押せる要素が対象を丸ごと包む(ラッパー)= 覆いではない
        let target = element(2, "button", "row", FTRect(x: 10, y: 400, width: 100, height: 40), depth: 2)
        let wrapper = element(4, "button", "wrapper", FTRect(x: 0, y: 300, width: 402, height: 300), depth: 2)
        let tree = [element(1, "other", "a", FTRect(x: 0, y: 0, width: 402, height: 874), depth: 1, scrollable: true),
                    target,
                    element(3, "other", "b", FTRect(x: 0, y: 200, width: 402, height: 600), depth: 1, scrollable: true),
                    wrapper]
        XCTAssertNil(TapTargetGeometry.otherLayerCoverSuspect(target, in: tree, screen: screen))
    }

    func testAnOtherWhollyInsideTheTargetIsNotSuspected() {
        let target = element(2, "button", "big", FTRect(x: 0, y: 300, width: 402, height: 300), depth: 2)
        let small = element(4, "button", "small", FTRect(x: 100, y: 400, width: 50, height: 50), depth: 2)
        let tree = [element(1, "other", "a", FTRect(x: 0, y: 0, width: 402, height: 874), depth: 1, scrollable: true),
                    target,
                    element(3, "other", "b", FTRect(x: 0, y: 200, width: 402, height: 600), depth: 1, scrollable: true),
                    small]
        XCTAssertNil(TapTargetGeometry.otherLayerCoverSuspect(target, in: tree, screen: screen))
    }

    func testNonOperableOtherIsNotSuspected() {
        var tree = sheetTree()
        tree[3].type = "staticText"
        XCTAssertNil(suspect(tree))
    }

    func testCentreOutsideTheScreenClosesTheGate() {
        var tree = sheetTree()
        tree[1].frame = FTRect(x: 0, y: 900, width: 402, height: 60)
        XCTAssertNil(suspect(tree))
    }

    func testOneSideWithoutAScrollContainerCountsAsAnotherLayer() {
        // 対象が容器の外(固定のバー)・相手が容器の中の行: 容器が違う
        var tree = sheetTree()
        tree.removeAll { $0.ref == 1 }
        XCTAssertEqual(suspect(tree)?.identifier, "queue_row_03")
    }
}

/// DSL の tap: 門が開く木で `hitTest(query:)` が false のときだけ撃たずに断る
final class OtherLayerHitTestWiringTests: XCTestCase {
    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    private func element(_ ref: Int, _ type: String, _ id: String, _ label: String, _ frame: FTRect, depth: Int,
                         scrollable: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil, placeholder: nil,
                    enabled: true, frame: frame, depth: depth, scrollable: scrollable)
    }

    private func sheetTree() -> [ElementInfo] {
        [element(1, "other", "list_main", "list_main", FTRect(x: 0, y: 0, width: 402, height: 874), depth: 1, scrollable: true),
         element(2, "button", "row_main_07", "本文 07", FTRect(x: 0, y: 400, width: 402, height: 60), depth: 2),
         element(3, "other", "list_queue", "list_queue", FTRect(x: 0, y: 300, width: 402, height: 574), depth: 1, scrollable: true),
         element(4, "button", "queue_row_03", "キュー 03", FTRect(x: 0, y: 380, width: 402, height: 60), depth: 2)]
    }

    private func closedGateTree() -> [ElementInfo] {
        // 同じ容器の中の重なり = 門は閉じる
        [element(1, "other", "list", "list", FTRect(x: 0, y: 0, width: 402, height: 874), depth: 1, scrollable: true),
         element(2, "button", "row_main_07", "本文 07", FTRect(x: 0, y: 400, width: 402, height: 60), depth: 2),
         element(4, "button", "queue_row_03", "キュー 03", FTRect(x: 0, y: 380, width: 402, height: 60), depth: 2)]
    }

    private func run(_ tree: [ElementInfo], answer: HitTestAnswer, android: Bool = false)
        async -> (FakeQueryDriver, StepOutcome) {
        let driver = FakeQueryDriver(elements: tree, screen: screen, answer: answer)
        let outcome = await StepExecutor(driver: driver, isAndroid: android, tunables: RunTunables())
            .execute(FlowStep(action: "tap", locator: FlowLocator(label: "本文 07")))
        return (driver, outcome)
    }

    func testFalseRefusesWithoutTouching() async {
        let (driver, outcome) = await run(sheetTree(), answer: .hittable(false))
        XCTAssertTrue(driver.taps.isEmpty, "撃った: \(driver.taps)")
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(message.contains("cannot be hit"), message)
        XCTAssertTrue(message.contains("queue_row_03"), "覆いを名指しすること: \(message)")
        XCTAssertEqual(driver.queries.count, 1)
        XCTAssertEqual(driver.queries.first?.identifier, "row_main_07")
    }

    func testTrueAndUnavailableAndUnresolvableStillFire() async {
        for answer in [HitTestAnswer.hittable(true), .unavailable, .unresolvable] {
            let (driver, outcome) = await run(sheetTree(), answer: answer)
            XCTAssertFalse(driver.taps.isEmpty, "\(answer): 撃たれなかった \(outcome.status)")
            XCTAssertEqual(driver.queries.count, 1, "\(answer)")
        }
    }

    func testClosedGateNeverAsks() async {
        let (driver, _) = await run(closedGateTree(), answer: .hittable(false))
        XCTAssertTrue(driver.queries.isEmpty, "門が閉じているのに照会した")
    }

    /// **見えている部分を押す判定が先**: 中心だけ別の層の帯(タブ)に覆われ、上に見えている部分が残る行は、照会が false でも
    /// 見えている部分を押す(照会しない)。照会を先に置くと中心で聞いて false になり、押せる行を断る誤った赤になる
    func testVisiblePartWinsOverTheQuery() async {
        let tree = [element(1, "other", "list_main", "list_main", FTRect(x: 0, y: 0, width: 402, height: 874), depth: 1, scrollable: true),
                    element(2, "button", "row_main_07", "本文 07", FTRect(x: 0, y: 760, width: 402, height: 100), depth: 2),
                    element(3, "button", "tab_home", "ホーム", FTRect(x: 0, y: 790, width: 402, height: 84), depth: 1)]
        XCTAssertNotNil(TapTargetGeometry.otherLayerCoverSuspect(tree[1], in: tree, screen: screen), "前提: 門は開く形")
        let (driver, outcome) = await run(tree, answer: .hittable(false))
        XCTAssertTrue(driver.queries.isEmpty, "見えている部分を押せる形で照会した: \(driver.queries)")
        XCTAssertEqual(driver.taps.count, 1, "見えている部分を撃つこと: \(driver.taps) \(outcome.status)")
        XCTAssertTrue(driver.taps.first?.hasPrefix("xy:") == true, "\(driver.taps)")
    }

    func testAndroidNeverAsks() async {
        let (driver, _) = await run(sheetTree(), answer: .hittable(false), android: true)
        XCTAssertTrue(driver.queries.isEmpty, "Android で照会した")
    }
}

private final class FakeQueryDriver: AppDriver, @unchecked Sendable {
    let elements: [ElementInfo]
    let screen: FTRect
    let answer: HitTestAnswer
    private(set) var taps: [String] = []
    private(set) var queries: [HitTestQuery] = []

    init(elements: [ElementInfo], screen: FTRect, answer: HitTestAnswer) {
        self.elements = elements
        self.screen = screen
        self.answer = answer
    }

    func hitTest(query: HitTestQuery) async -> HitTestAnswer {
        queries.append(query)
        return answer
    }

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws -> String? { nil }
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func terminate() async throws {}
    func screenshot() async throws -> Data { Data() }
    func type(ref: Int?, text: String) async throws {}
    func tap(ref: Int) async throws { taps.append("ref:\(ref)") }
    func tap(x: Double, y: Double) async throws { taps.append("xy:\(x),\(y)") }
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements, truncatedCount: 0)
    }
}
