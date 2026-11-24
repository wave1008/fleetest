// 実行機を通した DR-230 の出口: Android の Flutter のアプリでは、木の順で後ろの要素を「覆い」と名指さない。
// 抑えた事実(注記 occluderNamingSuppressed)は、案内を出す場面のステップにだけ付く(緑の手に毎回付けない)

import XCTest
@testable import FTCore

final class OccluderNamingExecutorTests: XCTestCase {
    private func elements() -> [ElementInfo] {
        let target = ElementInfo(ref: 1, type: "button", identifier: "fab_extended", label: "追加", value: nil,
                                 placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 300, width: 400, height: 60), depth: 1)
        let row = ElementInfo(ref: 2, type: "button", identifier: "row_f_10", label: "行 10", value: nil,
                              placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 320, width: 400, height: 60), depth: 1)
        let echo = ElementInfo(ref: 3, type: "staticText", identifier: "txt_result", label: "none", value: nil,
                               placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 100, width: 400, height: 30), depth: 1)
        return [target, row, echo]
    }

    private func executor(_ framework: AppUIFramework?) -> StepExecutor {
        let driver = FakeAppDriver(name: "d", log: CallLog(), snapshotElements: [elements()])
        driver.tapDeliveryAnswer = .syntheticTouch
        return StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables(), uiFramework: framework)
    }

    /// 緑の tap の注記: Flutter は名指さず抑えた事実を残す。Compose・不明は今どおり名指す
    func testGreenTapAdvisoryIsSuppressedOnlyForFlutter() async {
        for (framework, named) in [(AppUIFramework.flutter, false), (.compose, true), (nil, true)] as [(AppUIFramework?, Bool)] {
            let outcome = await executor(framework).execute(
                FlowStep(action: "tap", locator: FlowLocator(id: "fab_extended"), timeout: 0))
            XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "\(outcome.status)")
            let text = outcome.driverFallback ?? ""
            XCTAssertEqual(text.contains("row_f_10"), named, "\(String(describing: framework)): \(text)")
            XCTAssertEqual(outcome.notes.contains(.occluderNamingSuppressed), !named, "\(String(describing: framework))")
        }
    }

    /// 失敗後の案内: Flutter では直前の手の覆いの疑いを名指さず、抑えた事実は失敗したステップに付く
    func testFailureHintDoesNotNameTheRowForFlutter() async {
        for (framework, named) in [(AppUIFramework.flutter, false), (.compose, true)] as [(AppUIFramework?, Bool)] {
            let executor = executor(framework)
            _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "fab_extended"), timeout: 0))
            let failed = await executor.execute(FlowStep(assert: "textEquals", locator: FlowLocator(id: "txt_result"),
                                                         expected: "pressed", timeout: 0, occlusionGuard: false))
            guard case .failed(let message) = failed.status else { return XCTFail("\(failed.status)") }
            XCTAssertEqual(failed.notes.contains(.coveredTouchBeforeFailure), named, "\(String(describing: framework)): \(message)")
            XCTAssertEqual(message.contains("row_f_10"), named, message)
            if !named { XCTAssertTrue(failed.notes.contains(.occluderNamingSuppressed), "\(failed.notes)") }
        }
    }

    /// 名指しを抑えたら覆いの段だけ飛ばし、後段(ここでは同じ枠の積み重なり)は今どおり評価する
    func testSuppressedOverlayFallsThroughToTheNextStage() {
        let frame = FTRect(x: 0, y: 300, width: 400, height: 60)
        let target = ElementInfo(ref: 1, type: "button", identifier: "btn_a", label: "A", value: nil,
                                 placeholder: nil, enabled: true, frame: frame, depth: 2)
        let twinB = ElementInfo(ref: 2, type: "button", identifier: "btn_b", label: "B", value: nil,
                                placeholder: nil, enabled: true, frame: frame, depth: 2)
        let twinC = ElementInfo(ref: 3, type: "button", identifier: "btn_c", label: "C", value: nil,
                                placeholder: nil, enabled: true, frame: frame, depth: 2)
        let row = ElementInfo(ref: 4, type: "button", identifier: "row_f_10", label: "行 10", value: nil,
                              placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 320, width: 400, height: 60), depth: 2)
        let elements = [target, twinB, twinC, row]
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        let named = TapTargetGeometry.advisoryKindResult(for: target, in: elements, screen: screen, naming: .alwaysName)
        guard case .overlayCovering? = named.kind else { return XCTFail("前提: 名指せば覆いの段で止まる \(String(describing: named.kind))") }
        let flutter = TapTargetGeometry.advisoryKindResult(
            for: target, in: elements, screen: screen, naming: OccluderNamingContext(isAndroid: true, framework: .flutter))
        XCTAssertTrue(flutter.namingSuppressed)
        guard case .stacked? = flutter.kind else { return XCTFail("後段へ進む: \(String(describing: flutter.kind))") }
    }

    /// 覆いの疑い(撃つ前の幾何)だけが立つ形: 塗り順(z)では行が手前だが、木の順では行が対象より前 = 点を取る手前の要素
    /// (`frontElementTakingPoint`)は立たない。抑えた事実は、失敗後の案内を組んだステップに付く
    func testSuppressedCoverSuspicionIsNotedOnTheFailingStep() async {
        var row = ElementInfo(ref: 1, type: "button", identifier: "row_f_10", label: "行 10", value: nil,
                              placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 320, width: 400, height: 60), depth: 1)
        row.z = 2
        var target = ElementInfo(ref: 2, type: "button", identifier: "fab_extended", label: "追加", value: nil,
                                 placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 300, width: 400, height: 60), depth: 1)
        target.z = 1
        var echo = ElementInfo(ref: 3, type: "staticText", identifier: "txt_result", label: "none", value: nil,
                               placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 100, width: 400, height: 30), depth: 1)
        echo.z = 3
        let tree = [row, target, echo]
        XCTAssertNil(StepExecutor.frontElementTakingPoint(x: target.frame.centerX, y: target.frame.centerY, of: target, in: tree),
                     "前提: 木の順では点を取る手前の要素が無い")
        for (framework, suppressed) in [(AppUIFramework.flutter, true), (.compose, false)] as [(AppUIFramework?, Bool)] {
            let driver = FakeAppDriver(name: "d", log: CallLog(), snapshotElements: [tree])
            driver.tapDeliveryAnswer = .syntheticTouch
            let executor = StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables(), uiFramework: framework)
            _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "fab_extended"), timeout: 0))
            let failed = await executor.execute(FlowStep(assert: "textEquals", locator: FlowLocator(id: "txt_result"),
                                                         expected: "pressed", timeout: 0, occlusionGuard: false))
            guard case .failed = failed.status else { return XCTFail("\(failed.status)") }
            XCTAssertEqual(failed.notes.contains(.occluderNamingSuppressed), suppressed, "\(String(describing: framework)): \(failed.notes)")
            XCTAssertEqual(failed.notes.contains(.coveredTouchBeforeFailure), !suppressed, "\(String(describing: framework))")
        }
    }
}
