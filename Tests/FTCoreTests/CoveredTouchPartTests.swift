// OI-157: 操作可能な帯(タブ列)に中心を覆われた対象の「覆われていない見えている部分」の判定の固定。
import XCTest
@testable import FTCore

final class CoveredTouchPartTests: XCTestCase {
    private let screen = FTRect(x: 0, y: 0, width: 1080, height: 2400)

    private func el(_ ref: Int, _ type: String, id: String, _ r: FTRect) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: id, value: nil,
                    placeholder: nil, enabled: true, frame: r, depth: 2)
    }

    /// 下のタブ列が対象の下側(中心を含む)を覆う。タブ列は木で対象より後ろ = 手前
    private func tree(targetHeight: Double, tabTop: Double) -> (ElementInfo, [ElementInfo]) {
        let target = el(1, "button", id: "btn_input_submit", FTRect(x: 100, y: 2000, width: 800, height: targetHeight))
        let tab = el(2, "button", id: "tab_home", FTRect(x: 0, y: tabTop, width: 1080, height: 2400 - tabTop))
        return (target, [target, tab])
    }

    func testVisiblePartAboveTheTabBarIsPressedWhenItReachesTheFloor() {
        let (target, elements) = tree(targetHeight: 200, tabTop: 2080)   // 上の 80px が見える(中心 2100 は覆われる)
        guard case .visiblePart(let rect, let over)? = TapTargetGeometry.coveredTouch(
            for: target, in: elements, screen: screen, inferring: true, scale: 3) else {
            return XCTFail("見えている部分があれば押す")
        }
        XCTAssertEqual(over.identifier, "tab_home")
        XCTAssertEqual(rect.y, 2000)
        XCTAssertEqual(rect.height, 80)
        XCTAssertLessThan(rect.centerY, 2080, "押す点は覆いの外")
    }

    func testThinRemainderBelowTheFloorIsRefused() {
        let (target, elements) = tree(targetHeight: 200, tabTop: 2010)   // 残り 10px < 8*3
        guard case .tooThin(let visible, let floor, let over)? = TapTargetGeometry.coveredTouch(
            for: target, in: elements, screen: screen, inferring: true, scale: 3) else {
            return XCTFail("床に届かなければ撃たない")
        }
        XCTAssertEqual(visible, 10)
        XCTAssertEqual(floor, 24)
        XCTAssertEqual(over.identifier, "tab_home")
    }

    func testFloorScalesWithTheTreeUnit() {
        let (target, elements) = tree(targetHeight: 200, tabTop: 2010)   // 残り 10: scale 1 なら床 8 以上
        guard case .visiblePart? = TapTargetGeometry.coveredTouch(
            for: target, in: elements, screen: screen, inferring: true, scale: 1) else {
            return XCTFail("scale 1 なら床 8 を超える")
        }
    }

    func testUncoveredTargetIsNil() {
        let target = el(1, "button", id: "btn", FTRect(x: 100, y: 1000, width: 800, height: 100))
        let tab = el(2, "button", id: "tab_home", FTRect(x: 0, y: 2200, width: 1080, height: 200))
        XCTAssertNil(TapTargetGeometry.coveredTouch(for: target, in: [target, tab], screen: screen,
                                                    inferring: true, scale: 3))
    }
}

/// 指で触る操作の撃つ段が、覆われた対象の見えている部分の判定(`coveredTouchPlan`)を通ること(兄弟の取りこぼしを落とす)。
/// 打鍵・消去は欄の ref に撃つので通らない(`settleCoverAfterKeyboardClose(allowsVisiblePart: false)`)
final class CoveredTouchPlanWiringTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/FTCore/\(name)"), encoding: .utf8)
    }

    func testEveryFingerTouchFireSiteConsultsThePlan() throws {
        let actions = try source("StepExecutor+Actions.swift")
        // tap(押すだけ)・長押し・doubleTap・swipeElementToElement の始点
        XCTAssertGreaterThanOrEqual(actions.components(separatedBy: "coveredTouchPlan(element").count - 1, 4)
        XCTAssertTrue(try source("StepExecutor+Hold.swift").contains("coveredTouchPlan(element"), "holdStart")
    }

    func testTypeAndClearRefuseInsteadOfPressingAPart() throws {
        let actions = try source("StepExecutor+Actions.swift")
        XCTAssertTrue(actions.contains("verb: \"typing\", relift: relitAfterClose, allowsVisiblePart: false"))
        XCTAssertTrue(actions.contains("verb: \"clearing\", relift: relitAfterClose, allowsVisiblePart: false"))
    }
}
