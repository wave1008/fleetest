// DSL の setSliderValue(`StepExecutor` の action)。入れ物の中のスライダーへ寄せ、主のドライバにだけ自分の木の ref を渡し、
// typeDriver(XCUITest)へ回したときは ref を渡さない(別の名前空間)。どのブリッジも動かせなければ帯の上のタップで合わせる。

import XCTest
@testable import FTCore

extension StepExecutorTests {

    private func sliderElement(_ ref: Int, type: String = "slider", id: String?, value: String?, x: Double = 16,
                               width: Double = 370, depth: Int = 1) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: value, placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: 459, width: width, height: 31), depth: depth)
    }

    func testSetSliderValuePassesOwnRefAndCurrentValue() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[sliderElement(4, id: "slider_volume", value: "50%")]])
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())

        let outcome = await executor.execute(FlowStep(action: "setSliderValue", locator: FlowLocator(id: "slider_volume"),
                                                      text: "75"))

        guard case .passed = outcome.status else { return XCTFail("passed を期待: \(outcome.status)") }
        XCTAssertEqual(primary.lastSliderSet?.ref, 4)
        XCTAssertEqual(primary.lastSliderSet?.currentValue, "50%")
        XCTAssertEqual(primary.lastSliderSet?.value, 75)
    }

    /// **typeDriver(XCUITest)へ回したときは ref を渡さない**(主の木の番号は向こうでは別の要素を指す)
    func testFallbackToTypeDriverGetsNoRef() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[sliderElement(4, id: "slider_volume", value: "50%")]])
        primary.sliderError = DriverError.badResponse(status: 501, body: "not adjustable")
        let typeDriver = FakeAppDriver(name: "type", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, isAndroid: false, tunables: RunTunables())

        let outcome = await executor.execute(FlowStep(action: "setSliderValue", locator: FlowLocator(id: "slider_volume"),
                                                      text: "75"))

        guard case .passed = outcome.status else { return XCTFail("passed を期待: \(outcome.status)") }
        XCTAssertEqual(primary.lastSliderSet?.ref, 4)
        XCTAssertNotNil(typeDriver.lastSliderSet, "typeDriver へ回っていない")
        XCTAssertNil(typeDriver.lastSliderSet?.ref, "別の名前空間の ref を渡した")
    }

    /// 入れ物の中のスライダーちょうど1つへ寄せる(ref・現在値はスライダーのもの)。2つなら撃たずに断る
    func testContainerResolvesToTheInnerSliderAndRefusesTwo() async throws {
        let log = CallLog()
        let container = sliderElement(1, type: "other", id: "slider_volume", value: nil)
        let inner = sliderElement(2, id: nil, value: "50%", x: 177, width: 48, depth: 2)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[container, inner]])
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())

        let outcome = await executor.execute(FlowStep(action: "setSliderValue", locator: FlowLocator(id: "slider_volume"),
                                                      text: "75"))
        guard case .passed = outcome.status else { return XCTFail("passed を期待: \(outcome.status)") }
        XCTAssertEqual(primary.lastSliderSet?.ref, 2)
        XCTAssertEqual(primary.lastSliderSet?.currentValue, "50%")

        let two = FakeAppDriver(name: "two", log: log, snapshotElements: [[
            sliderElement(1, type: "other", id: "range", value: nil),
            sliderElement(2, id: nil, value: "20", x: 30, width: 48, depth: 2),
            sliderElement(3, id: nil, value: "80", x: 300, width: 48, depth: 2),
        ]])
        let refused = await StepExecutor(driver: two, isAndroid: false, tunables: RunTunables())
            .execute(FlowStep(action: "setSliderValue", locator: FlowLocator(id: "range"), text: "50"))
        guard case .failed(let message) = refused.status else { return XCTFail("failed を期待: \(refused.status)") }
        XCTAssertTrue(message.contains("holds 2 sliders"), message)
        XCTAssertNil(two.lastSliderSet)
    }

    /// どのブリッジも動かせなければ(501)帯の上のタップで合わせ、そう注記する
    func testIncapableBridgesFallToTappingAlongTheTrack() async throws {
        let log = CallLog()
        let frame = FTRect(x: 16, y: 459, width: 370, height: 31)
        func tree(_ value: Int) -> [ElementInfo] {
            [ElementInfo(ref: 1, type: "other", identifier: "slider_volume", label: nil, value: "\(value)%", placeholder: nil,
                         enabled: true, frame: frame, depth: 1)]
        }
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [tree(50)])
        primary.sliderError = DriverError.badResponse(status: 501, body: "no slider-type element")
        primary.afterCoordinateTap = { [unowned primary] in
            let x = primary.coordinateTaps.last!.x
            primary.snapshotElements = [tree(min(100, max(0, Int(((x - frame.x) / frame.width * 4).rounded()) * 25)))]
        }
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())

        let outcome = await executor.execute(FlowStep(action: "setSliderValue", locator: FlowLocator(id: "slider_volume"),
                                                      text: "75"))

        guard case .passed = outcome.status else { return XCTFail("passed を期待: \(outcome.status)") }
        XCTAssertFalse(primary.coordinateTaps.isEmpty)
        XCTAssertTrue(outcome.driverFallback?.contains("set by tapping along the slider") == true, outcome.driverFallback ?? "nil")
    }

    /// Android はスライダーでない要素・木の範囲の外を撃つ前に断る(何も送らない)
    func testAndroidRefusesANonSliderAndAnOutOfRangeValueWithoutSending() async throws {
        let log = CallLog()
        let button = sliderElement(1, type: "button", id: "btn_x", value: nil)
        let notSlider = FakeAppDriver(name: "button", log: log, snapshotElements: [[button]])
        let refused = await StepExecutor(driver: notSlider, isAndroid: true, tunables: RunTunables())
            .execute(FlowStep(action: "setSliderValue", locator: FlowLocator(id: "btn_x"), text: "50"))
        guard case .failed(let message) = refused.status else { return XCTFail("failed を期待: \(refused.status)") }
        XCTAssertTrue(message.contains("#btn_x is not a slider"), message)
        XCTAssertNil(notSlider.lastSliderSet)

        var slider = sliderElement(2, id: "slider_volume", value: "50")
        slider.range = "0-100"
        let ranged = FakeAppDriver(name: "ranged", log: log, snapshotElements: [[slider]])
        let outside = await StepExecutor(driver: ranged, isAndroid: true, tunables: RunTunables())
            .execute(FlowStep(action: "setSliderValue", locator: FlowLocator(id: "slider_volume"), text: "150"))
        guard case .failed(let outsideMessage) = outside.status else { return XCTFail("failed を期待: \(outside.status)") }
        XCTAssertTrue(outsideMessage.contains("outside what the slider reaches (0 to 100"), outsideMessage)
        XCTAssertNil(ranged.lastSliderSet)
    }
}
