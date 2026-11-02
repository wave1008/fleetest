// ロケータなしの type / clearInput / pressEnter(焦点の欄へ撃つ形)を、Android で前面が起こしたアプリでないときに
// 注記 `ref-less-input-on-other-app` で言う(撃つ。断らない = 新しい検知は警告から)。判定は MCP と共有の
// `PreFireGuard.refLessInputBlocked`。起こしていない(home / アプリ切替の後)・iOS では聞かない。

import XCTest
@testable import FTCore

final class RefLessInputFrontAppNoteTests: XCTestCase {

    private func run(_ step: FlowStep, front: Probe<String>, isAndroid: Bool = true,
                     launched: String? = "com.example.app") async -> (StepOutcome, CallLog) {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log)
        driver.foregroundAppIDAnswer = front
        let executor = StepExecutor(driver: driver, isAndroid: isAndroid, tunables: RunTunables())
        executor.launchedBundleID = launched
        return (await executor.execute(step), log)
    }

    func testTypeIntoAnotherAppsFieldIsNotedButStillSent() async {
        let (outcome, log) = await run(FlowStep(action: "type", text: "abc"), front: .value("com.android.chrome"))
        XCTAssertTrue(outcome.notes.contains(.refLessInputOnOtherApp), "\(outcome.notes)")
        XCTAssertTrue(log.entries.contains("primary.type(ref:nil)"), "\(log.entries)")
    }

    func testClearAndEnterAreNotedToo() async {
        for step in [FlowStep(action: "clearInput"), FlowStep(action: "pressEnter")] {
            let (outcome, _) = await run(step, front: .value("com.android.chrome"))
            XCTAssertTrue(outcome.notes.contains(.refLessInputOnOtherApp), "\(step.action ?? ""): \(outcome.notes)")
        }
    }

    func testSilentWhileTheLaunchedAppIsInFront() async {
        let (outcome, _) = await run(FlowStep(action: "type", text: "abc"), front: .value("com.example.app"))
        XCTAssertFalse(outcome.notes.contains(.refLessInputOnOtherApp), "\(outcome.notes)")
    }

    /// システムのダイアログの欄へ打つのは正規の操作・読めないことを「別のアプリ」と読まない
    func testSilentForASystemDialogOrAnUnreadableFront() async {
        let dialog = try! XCTUnwrap(ForegroundState.systemDialogPackages.first)
        for front in [Probe<String>.value(dialog), .notAnswerable, .failed("x")] {
            let (outcome, _) = await run(FlowStep(action: "type", text: "abc"), front: front)
            XCTAssertFalse(outcome.notes.contains(.refLessInputOnOtherApp), "\(front): \(outcome.notes)")
        }
    }

    /// iOS・起こしていない(home / アプリ切替の後)は前面を聞かない(往復を足さない)
    func testDoesNotAskOnIOSOrWithoutALaunchedApp() async {
        for (isAndroid, launched) in [(false, Optional("com.example.app")), (true, nil)] {
            let (outcome, log) = await run(FlowStep(action: "type", text: "abc"), front: .value("com.android.chrome"),
                                           isAndroid: isAndroid, launched: launched)
            XCTAssertFalse(outcome.notes.contains(.refLessInputOnOtherApp))
            XCTAssertFalse(log.entries.contains("primary.foregroundAppID"), "\(log.entries)")
        }
    }
}
