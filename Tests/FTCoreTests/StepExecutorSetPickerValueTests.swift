// DSL の setPickerValue(`StepExecutor` の action)。対象は pickerWheel 1本・値が空・型違い・複数本は撃たずに断る。
// 撃つときは座標系の違うブリッジ間で通じる frame を渡し、501 は typeDriver(XCUITest)へ回す(pinch と同じ)。

import XCTest
@testable import FTCore

extension StepExecutorTests {

    private func wheelElement(_ ref: Int, id: String, value: String?, y: Double, type: String = "pickerWheel") -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: value, placeholder: nil, enabled: true,
                    frame: FTRect(x: 20, y: y, width: 100, height: 40), depth: 1)
    }

    func testSetPickerValuePassesFrameAndCurrentValue() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[wheelElement(1, id: "hour", value: "14時", y: 100)]])
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())

        let outcome = await executor.execute(FlowStep(action: "setPickerValue", locator: FlowLocator(id: "hour"), text: "19"))

        guard case .passed = outcome.status else { return XCTFail("passed を期待: \(outcome.status)") }
        XCTAssertEqual(primary.lastPickerSet?.value, "19")
        XCTAssertEqual(primary.lastPickerSet?.currentValue, "14時")
        XCTAssertEqual(primary.lastPickerSet?.frame, FTRect(x: 20, y: 100, width: 100, height: 40))
        XCTAssertTrue(outcome.driverFallback?.contains("now reads \"19\"") == true, outcome.driverFallback ?? "nil")
    }

    func testSetPickerValueRefusesANonPickerWheelWithoutSending() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[wheelElement(1, id: "hour", value: nil, y: 100, type: "datePicker")]])
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())

        let outcome = await executor.execute(FlowStep(action: "setPickerValue", locator: FlowLocator(id: "hour"), text: "19"))

        guard case .failed(let message) = outcome.status else { return XCTFail("failed を期待: \(outcome.status)") }
        XCTAssertTrue(message.contains("needs a pickerWheel") && message.contains("datePicker"), message)
        XCTAssertNil(primary.lastPickerSet)
    }

    func testSetPickerValueRefusesSeveralWheelsAndEmptyValue() async throws {
        let log = CallLog()
        let two = [wheelElement(1, id: "w", value: "1", y: 100), wheelElement(2, id: "w", value: "2", y: 200)]
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [two])
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())

        let ambiguous = await executor.execute(FlowStep(action: "setPickerValue", locator: FlowLocator(id: "w"), text: "9"))
        guard case .failed(let message) = ambiguous.status else { return XCTFail("failed を期待") }
        XCTAssertTrue(message.contains("matches 2 picker wheels"), message)

        let empty = await executor.execute(FlowStep(action: "setPickerValue", locator: FlowLocator(id: "w"), text: " "))
        guard case .failed(let emptyMessage) = empty.status else { return XCTFail("failed を期待") }
        XCTAssertTrue(emptyMessage.contains("non-empty value"), emptyMessage)
        XCTAssertNil(primary.lastPickerSet, "断った回は何も撃たない")
    }

    /// 序数で1本を選んだセレクタは、ホイールが複数あっても断らない(実測: `.pickerWheel[1]` まで「2本に当たる」で断っていた)
    func testSetPickerValueAcceptsAnIndexedSelectorAmongSeveralWheels() async throws {
        let log = CallLog()
        let two = [wheelElement(1, id: "w", value: "9", y: 100), wheelElement(2, id: "w", value: "30", y: 200)]
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [two])
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        var second = FlowLocator(id: "w")
        second.index = 1
        let outcome = await executor.execute(FlowStep(action: "setPickerValue", locator: second, text: "45"))
        guard case .passed = outcome.status else { return XCTFail("passed を期待: \(outcome.status)") }
        XCTAssertEqual(primary.lastPickerSet?.currentValue, "30", "2本目のホイールを回す")
    }

    func testSetPickerValueFailureCarriesTheStoppedValue() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[wheelElement(1, id: "hour", value: "14", y: 100)]])
        primary.pickerError = DriverError.badResponse(status: 422, body: "the picker stopped at '23', not '99'")
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())

        let outcome = await executor.execute(FlowStep(action: "setPickerValue", locator: FlowLocator(id: "hour"), text: "99"))

        guard case .failed(let message) = outcome.status else { return XCTFail("failed を期待: \(outcome.status)") }
        XCTAssertTrue(message.contains("stopped at '23'"), message)
    }

    func testSetPickerValueFallsBackToTypeDriverWhenBridgeIncapable() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[wheelElement(1, id: "hour", value: "14", y: 100)]])
        primary.pickerError = DriverError.badResponse(status: 501, body: "in-app")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, isAndroid: false, tunables: RunTunables())

        let outcome = await executor.execute(FlowStep(action: "setPickerValue", locator: FlowLocator(id: "hour"), text: "19"))

        guard case .passed = outcome.status else { return XCTFail("passed を期待: \(outcome.status)") }
        XCTAssertEqual(typeDriver.lastPickerSet?.value, "19")
        XCTAssertTrue(outcome.driverFallback?.contains("fell back to XCUITest") == true, outcome.driverFallback ?? "nil")
    }
}
