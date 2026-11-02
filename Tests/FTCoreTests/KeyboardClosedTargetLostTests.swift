// キーボードで潰れた対象を、閉じてから引き直せなければ**撃たずに失敗にする**ことを固定する。
// 閉じる前の要素は前の木の ref と枠なので、撃つと別の物に当たって ok になる(寄せの後と同じ型。StraddleNudgeTests)

import XCTest
@testable import FTCore

/// キーボード表示中は対象が高さ 2 に潰れて木に居る。閉じると対象ごと木から消える
private final class CollapsedUnderKeyboardDriver: AppDriver {
    private var keyboardUp = true
    private(set) var taps = 0
    private(set) var hides = 0

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws -> String? { nil }
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func terminate() async throws {}
    func screenshot() async throws -> Data { Data() }
    func type(ref: Int?, text: String) async throws {}
    func tap(ref: Int) async throws { taps += 1 }
    func tap(x: Double, y: Double) async throws { taps += 1 }
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func hideKeyboard() async throws { hides += 1; keyboardUp = false }
    func doubleTap(ref: Int) async throws { taps += 1 }
    func doubleTap(x: Double, y: Double) async throws { taps += 1 }

    func snapshot() async throws -> SnapshotResponse {
        let screen = FTRect(x: 0, y: 0, width: 1080, height: 2400)
        var elements = [ElementInfo(ref: 1, type: "button", identifier: "other", label: "他", value: nil,
                                    placeholder: nil, enabled: true, frame: FTRect(x: 40, y: 200, width: 400, height: 120),
                                    depth: 1)]
        if keyboardUp {
            elements.append(ElementInfo(ref: 2, type: "button", identifier: "target", label: "対象", value: nil,
                                        placeholder: nil, enabled: true, frame: FTRect(x: 40, y: 1400, width: 400, height: 2),
                                        depth: 1))
        }
        return SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements, truncatedCount: 0,
                                keyboardFrame: keyboardUp ? FTRect(x: 0, y: 1500, width: 1080, height: 900) : nil)
    }
}

final class KeyboardClosedTargetLostTests: XCTestCase {

    func testTargetGoneAfterClosingTheKeyboardFailsWithoutTouching() async throws {
        let driver = CollapsedUnderKeyboardDriver()

        let outcome = await StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "target")))

        XCTAssertGreaterThan(driver.hides, 0, "キーボードを閉じる経路を通っていない")
        XCTAssertEqual(driver.taps, 0, "閉じる前の要素のまま撃った")
        guard case .failed(let message) = outcome.status else {
            return XCTFail("閉じた後に対象が消えたのに失敗にならない: \(outcome.status)")
        }
        XCTAssertTrue(message.contains("could not be found on the screen afterwards"), message)
    }

    /// tap 以外の指で触る操作は撃つ前の入口(`reachBeforeTouch`)を通る。そちらも同じ
    func testDoubleTapAlsoFailsWithoutTouching() async throws {
        let driver = CollapsedUnderKeyboardDriver()

        let outcome = await StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())
            .execute(FlowStep(action: "doubleTap", locator: FlowLocator(id: "target")))

        XCTAssertGreaterThan(driver.hides, 0, "キーボードを閉じる経路を通っていない")
        XCTAssertEqual(driver.taps, 0, "閉じる前の要素のまま撃った")
        guard case .failed(let message) = outcome.status else {
            return XCTFail("閉じた後に対象が消えたのに失敗にならない: \(outcome.status)")
        }
        XCTAssertTrue(message.contains("could not be found on the screen afterwards"), message)
    }
}
