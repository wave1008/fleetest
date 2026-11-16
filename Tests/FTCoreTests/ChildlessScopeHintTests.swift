// スコープの容器が木の上で中身を持たないときの「見つからない」の事実(LocatorResolver.childlessScopeContainer)。
// 木は sut-ec-mobile のカート(iOS・CMP 1.11)を in-app で採った形: testTag だけの Row `#cart_item_fashion_5` は
// 子の無い葉で、行の中身は同じ深さの兄弟として並ぶ(Android は同じ画面を入れ子で出す)

import XCTest
@testable import FTCore

final class ChildlessScopeHintTests: XCTestCase {

    private func node(_ ref: Int, _ type: String, depth: Int, id: String? = nil, label: String? = nil,
                      _ x: Double, _ y: Double, _ width: Double, _ height: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: width, height: height), depth: depth)
    }

    /// iOS の CMP: 容器は葉・中身は兄弟
    private var flattened: [ElementInfo] {
        [
            node(1, "other", depth: 8, id: "screen_cart", 0, 62, 402, 698),
            node(2, "staticText", depth: 9, label: "カート", 16, 145, 57, 23),
            node(3, "other", depth: 10, id: "cart_item_fashion_5", 16, 212, 370, 94),
            node(4, "staticText", depth: 10, label: "ミニマルデザイン腕時計", 120, 212, 226, 16),
            node(5, "button", depth: 10, id: "btn_remove_fashion_5", label: "削除", 346, 204, 48, 48),
            node(6, "button", depth: 10, id: "btn_qty_decrement", label: "数量を減らす", 114, 264, 48, 48),
        ]
    }

    /// Android: 同じ画面の入れ子の木
    private var nested: [ElementInfo] {
        [
            node(1, "other", depth: 1, id: "screen_cart", 0, 62, 402, 698),
            node(3, "other", depth: 2, id: "cart_item_fashion_5", 16, 212, 370, 94),
            node(4, "staticText", depth: 3, label: "ミニマルデザイン腕時計", 120, 212, 226, 16),
            node(5, "button", depth: 3, id: "btn_remove_fashion_5", label: "削除", 346, 204, 48, 48),
        ]
    }

    private func scoped(_ target: FlowLocator, _ containers: String...) -> FlowLocator {
        var locator = target
        locator.scope = containers.map { FlowLocator(id: $0) }
        return locator
    }

    func testNamesTheContainerOnlyWhenItHasNothingUnderIt() {
        let locator = scoped(FlowLocator(id: "btn_remove_fashion_5"), "cart_item_fashion_5")
        XCTAssertEqual(LocatorResolver.childlessScopeContainer(of: locator, in: flattened)?.ref, 3)
        // 入れ子の木では言わない(本当に中に無いだけ)
        XCTAssertNil(LocatorResolver.childlessScopeContainer(of: scoped(FlowLocator(id: "missing"), "cart_item_fashion_5"),
                                                             in: nested))
        // 容器そのものが見つからないときも言わない(別の理由)
        XCTAssertNil(LocatorResolver.childlessScopeContainer(of: scoped(FlowLocator(id: "x"), "no_such_row"), in: flattened))
        // スコープが無ければ言わない
        XCTAssertNil(LocatorResolver.childlessScopeContainer(of: FlowLocator(id: "x"), in: flattened))
    }

    /// 連鎖は外側から辿り、中身の無い最初の段を名指す(外側の容器は中身を持つ)
    func testChainedScopeNamesTheFirstChildlessLevel() {
        let locator = scoped(FlowLocator(id: "btn_remove_fashion_5"), "screen_cart", "cart_item_fashion_5")
        XCTAssertEqual(LocatorResolver.childlessScopeContainer(of: locator, in: flattened)?.identifier, "cart_item_fashion_5")
    }

    private func executor(_ elements: [ElementInfo], isAndroid: Bool = false) -> StepExecutor {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [elements])
        return StepExecutor(driver: driver, typeDriver: nil, isAndroid: isAndroid, tunables: RunTunables(), uiFramework: .compose)
    }

    private func message(_ status: StepResult.Status) -> String {
        if case .failed(let text) = status { return text }
        return "\(status)"
    }

    /// 操作: 待ち・送りの案内の代わりに、容器が中身を持たない事実と書き方を言う(待っても出ない)
    func testTapFailureSaysTheContainerHasNothingUnderItInsteadOfWaitAdvice() async {
        let outcome = await executor(flattened).execute(
            FlowStep(action: "tap", locator: scoped(FlowLocator(id: "btn_remove_fashion_5"), "cart_item_fashion_5")))
        let text = message(outcome.status)
        XCTAssertTrue(text.contains("cannot resolve the locator"), text)
        XCTAssertTrue(text.contains("the scope's container #cart_item_fashion_5"), text)
        XCTAssertTrue(text.contains("has nothing under it"), text)
        XCTAssertFalse(text.contains("add waitSeconds"), text)
        XCTAssertEqual(outcome.failureKind, .notFound)
        // 対象そのものは木にある = 似た名前の候補(隣の行)を勧めない(57周目 alocal F1)。理由は容器に中身が無いことを先に言う
        XCTAssertFalse(text.contains("near matches"), text)
    }

    /// 中身のある容器の外に対象が居る: 「スコープの外」とだけ言い、待ち・送りの案内も近い候補も添えない。検証も同じ(58周目)
    func testTargetOutsideAContainerWithContentSaysSoAndNothingElse() async {
        let locator = scoped(FlowLocator(id: "btn_qty_decrement"), "cart_item_fashion_5")
        for step in [FlowStep(action: "tap", locator: locator), FlowStep(assert: "exists", locator: locator, timeout: 0.2)] {
            let text = message(await executor(nested + [node(6, "button", depth: 1, id: "btn_qty_decrement", label: "数量を減らす",
                                                          114, 400, 48, 48)]).execute(step).status)
            XCTAssertTrue(text.contains("the target itself is in the tree (button #btn_qty_decrement"), text)
            XCTAssertTrue(text.contains("but not inside the scope"), text)
            XCTAssertFalse(text.contains("add waitSeconds"), text)
            XCTAssertFalse(text.contains("add scroll:"), text)
            XCTAssertFalse(text.contains("near matches"), text)
        }
    }

    /// 容器が木に無く、対象は居る: 容器が無いと言う(閉じろ・待て・送れは言わない)
    func testScopeContainerMissingButTargetPresent() async {
        let locator = scoped(FlowLocator(id: "btn_remove_fashion_5"), "no_such_row")
        let text = message(await executor(nested).execute(FlowStep(assert: "exists", locator: locator, timeout: 0.2)).status)
        XCTAssertTrue(text.contains("but the scope's container is not"), text)
    }

    /// 送りの探索の失敗も、スコープの理由があればそれだけを言う(58周目 im4 F3: withScrollRight の中で「withScrollRight で包め」と循環した)
    func testScrollSearchFailureSaysOnlyTheScopeReason() {
        var result = StepExecutor.ScrollSearchResult(found: false, fallback: nil, viaXCUITest: false, hintJumps: 0, swipes: 3)
        result.stoppedUnmoving = true
        result.directionMatchedScrollFrameCandidate = "#stab_row"
        result.scopeHint = " (the scope's container #stab_row is in the tree but has nothing under it)"
        var step = FlowStep(action: "tap", locator: scoped(FlowLocator(id: "stab_10"), "stab_row"))
        step.direction = "left"
        let text = StepExecutor.scrollNotFoundMessage(step, result, defaultMaxSwipes: 8)
        XCTAssertTrue(text.contains("has nothing under it"), text)
        XCTAssertFalse(text.contains("withScroll"), text)
        XCTAssertFalse(text.contains("waitSeconds"), text)
        // 理由が無ければ従来どおり
        result.scopeHint = ""
        XCTAssertTrue(StepExecutor.scrollNotFoundMessage(step, result, defaultMaxSwipes: 8).contains("withScroll"))
    }

    /// スコープの外にも対象が無ければ、従来どおり似た名前の候補を挙げる
    func testNearMatchesStayWhenTheTargetIsNowhere() async {
        let outcome = await executor(flattened).execute(
            FlowStep(action: "tap", locator: scoped(FlowLocator(id: "btn_remove"), "cart_item_fashion_5")))
        let text = message(outcome.status)
        XCTAssertTrue(text.contains("near matches"), text)
        XCTAssertFalse(text.contains("the target itself is in the tree"), text)
    }

    /// 検証(exist)の失敗にも添える
    func testExistFailureSaysTheContainerHasNothingUnderIt() async {
        let outcome = await executor(flattened).execute(
            FlowStep(assert: "exists", locator: scoped(FlowLocator(id: "btn_remove_fashion_5"), "cart_item_fashion_5"),
                     timeout: 0.2))
        let text = message(outcome.status)
        XCTAssertTrue(text.contains("element not found"), text)
        XCTAssertTrue(text.contains("has nothing under it"), text)
    }

    /// 中身を持つ容器のスコープで外れたときは言わず、従来の待ちの案内のまま
    func testOrdinaryScopeMissKeepsTheWaitAdvice() async {
        let outcome = await executor(nested).execute(
            FlowStep(action: "tap", locator: scoped(FlowLocator(id: "missing"), "cart_item_fashion_5")))
        let text = message(outcome.status)
        XCTAssertFalse(text.contains("has nothing under it"), text)
        XCTAssertTrue(text.contains("add waitSeconds"), text)
    }

    /// 理由は木の形と OS から言えるものだけ: iOS の入れ物の型だけ CMP の平坦化を言い、葉の型は「中身を持たない型」と言う。
    /// Android では CMP を持ち出さない。例は特定のアプリの id を出さない(56周目 im4 F1・amax F1 = SwiftUI / View のアプリで CMP の説明が出た)
    func testReasonFollowsTheContainerTypeAndPlatform() async {
        let leaf = [
            node(1, "staticText", depth: 5, id: "txt_row_selected", 0, 100, 200, 20),
            node(2, "staticText", depth: 5, id: "row_02", 0, 200, 200, 20),
        ]
        let leafScope = scoped(FlowLocator(id: "row_02"), "txt_row_selected")
        for isAndroid in [false, true] {
            let text = message(await executor(leaf, isAndroid: isAndroid).execute(FlowStep(action: "tap", locator: leafScope)).status)
            XCTAssertTrue(text.contains("has nothing under it"), text)
            XCTAssertTrue(text.contains("it is a staticText, which holds no other elements"), text)
            XCTAssertFalse(text.contains("Compose Multiplatform"), text)
            XCTAssertFalse(text.contains("btn_qty_decrement"), text)
        }
        let groupScope = scoped(FlowLocator(id: "btn_remove_fashion_5"), "cart_item_fashion_5")
        let ios = message(await executor(flattened).execute(FlowStep(action: "tap", locator: groupScope)).status)
        XCTAssertTrue(ios.contains("Compose Multiplatform"), ios)
        XCTAssertFalse(ios.contains("btn_qty_decrement"), ios)
        let android = message(await executor(flattened, isAndroid: true).execute(FlowStep(action: "tap", locator: groupScope)).status)
        XCTAssertTrue(android.contains("has nothing under it"), android)
        XCTAssertFalse(android.contains("Compose Multiplatform"), android)
    }
}
