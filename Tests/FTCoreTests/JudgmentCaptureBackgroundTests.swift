// 背面の画像判定: 前面を離れたかもしれない印が立っていて前面の照会が「前面に無い」と答えたら、
// in-app の絵(背面でもアプリ自身の window を描く)でなく XCUITest の絵で判定する。

@testable import FTCore
import XCTest

final class JudgmentCaptureBackgroundTests: XCTestCase {

    func testSourceGoesWholeScreenOnlyWhenAnsweredNotInForeground() {
        func src(_ front: Bool?) -> JudgmentCapture.Source {
            JudgmentCapture.source(primaryOmitsSystemUI: true, hasWholeScreen: true, alwaysWholeScreen: false,
                                   keyboardShown: false, alertCovering: false, appInForeground: front)
        }
        XCTAssertEqual(src(false), .wholeScreen)
        XCTAssertEqual(src(true), .primary)
        XCTAssertEqual(src(nil), .primary)
        XCTAssertEqual(JudgmentCapture.source(primaryOmitsSystemUI: false, hasWholeScreen: true, alwaysWholeScreen: false,
                                              keyboardShown: false, alertCovering: false, appInForeground: false),
                       .primary, "主ドライバが画面全体を撮る構成は変えない")
    }

    private func make() -> (StepExecutor, FakeAppDriver) {
        let log = CallLog()
        let primary = FakeAppDriver(name: "inapp", log: log, screenshots: [Data([1])])
        let whole = FakeAppDriver(name: "xcuitest", log: log, screenshots: [Data([2])])
        whole.systemAlertFrames = [SystemAlertProbeResponse(present: false)]
        let executor = StepExecutor(driver: primary, fallbackDriver: whole, primaryCaptureOmitsSystemUI: true,
                                    isAndroid: false, tunables: RunTunables())
        executor.noteAppLaunched(bundleID: "com.example.app")
        return (executor, whole)
    }

    func testBackgroundedAppIsJudgedFromTheWholeScreen() async throws {
        let (executor, whole) = make()
        executor.noteAppMayHaveLeft(true)
        whole.appForeground = false
        var phase = StepExecutor.PhaseAccumulator()
        let shot = try await executor.judgmentScreenshot(keyboardShown: false, phase: &phase)
        XCTAssertEqual(shot, Data([2]))
    }

    func testForegroundOrUnmarkedKeepsThePrimary() async throws {
        let (executor, whole) = make()
        whole.appForeground = false
        var phase = StepExecutor.PhaseAccumulator()
        let unmarked = try await executor.judgmentScreenshot(keyboardShown: false, phase: &phase)
        XCTAssertEqual(unmarked, Data([1]), "印が無いのに照会の答えで寄せた")
        executor.noteAppMayHaveLeft(true)
        whole.appForeground = true
        let front = try await executor.judgmentScreenshot(keyboardShown: false, phase: &phase)
        XCTAssertEqual(front, Data([1]))
    }
}
