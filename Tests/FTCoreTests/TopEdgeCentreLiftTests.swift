// 焦点を立てる操作(type)の前に、欄の中心が欄を切り取る容器の上端の外なら、容器を逆向きに送って中へ戻す
// (OI-167 ④⑤: 直前の欄をキーボードの下から出す送りが次の欄を容器の上へ押し出し、中心を叩くと容器の外に当たって
// 焦点が前の欄に残った)。木は E2EX-RN の実測の枠(欄 (16,234 370x56)・容器 (16,266.3 370x387.7))

import XCTest
@testable import FTCore

final class TopEdgeCentreLiftTests: XCTestCase {

    private let container = FTRect(x: 16, y: 266.3, width: 370, height: 387.7)

    private func field(_ ref: Int, _ id: String, y: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: "textField", identifier: id, label: nil, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 16, y: y, width: 370, height: 56), depth: 2)
    }

    private func form(numberY: Double) -> [ElementInfo] {
        [ElementInfo(ref: 1, type: "scrollView", identifier: nil, label: nil, value: nil, placeholder: nil,
                     enabled: true, frame: container, depth: 1, scrollable: true),
         field(2, "field_second", y: 400), field(3, "field_number", y: numberY)]
    }

    func testCentreAboveTheContainerTopIsLiftedBackInwardsNegativeDirection() throws {
        let number = field(3, "field_number", y: 234)
        let jump = try XCTUnwrap(TapTargetGeometry.topEdgeCentreLift(number, container: container))
        XCTAssertLessThan(jump, 0, "上へ押し出された欄は内容を下へ戻す(負)")
        XCTAssertGreaterThanOrEqual(-jump, container.y - number.frame.y, "上端を越えた分以上は戻す")
    }

    func testCentreInsideOrWhollyOutsideIsNotLifted() {
        // 中心が容器の中(上端をまたぐが中心は中)
        XCTAssertNil(TapTargetGeometry.topEdgeCentreLift(field(3, "a", y: 250), container: container))
        // 欄が完全に容器の外(通り過ぎた)
        XCTAssertNil(TapTargetGeometry.topEdgeCentreLift(field(3, "b", y: 150), container: container))
        // 容器の中
        XCTAssertNil(TapTargetGeometry.topEdgeCentreLift(field(3, "c", y: 300), container: container))
    }

    func testTypeSendsTheContainerBackBeforeTappingAFieldClippedAtTheTop() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [form(numberY: 234), form(numberY: 300)])
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let outcome = await executor.execute(FlowStep(action: "type", locator: FlowLocator(id: "field_number"), text: "4"))
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status) \(log.entries)") }
        XCTAssertGreaterThan(primary.dragCalls.count, 0, "上端で切り取られた欄を送らずに叩いた: \(log.entries)")
        XCTAssertTrue((outcome.driverFallback ?? "").contains("top edge of its scroll container"), outcome.driverFallback ?? "")
        let typeIndex = try XCTUnwrap(log.entries.firstIndex { $0.hasPrefix("primary.type(") }, "\(log.entries)")
        XCTAssertFalse(log.entries[typeIndex...].contains { $0.contains("drag") }, "送りは打つ前")
    }

    func testTypeDoesNotSendWhenTheFieldCentreIsInsideTheContainer() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [form(numberY: 300)])
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let outcome = await executor.execute(FlowStep(action: "type", locator: FlowLocator(id: "field_number"), text: "4"))
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status) \(log.entries)") }
        XCTAssertEqual(primary.dragCalls.count, 0, "\(log.entries)")
    }
}
