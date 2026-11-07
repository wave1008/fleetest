import XCTest
@testable import FTCore

/// 「対象アプリをこのシナリオで止めた」の事実は1つ(`AppUnderTestLifeRecord`)。DSL と StepExecutor に別々に持っていた頃、照会で「居る」と
/// 分かったとき(`noteFoundRunning`)に DSL 側だけが起動済みへ戻り、StepExecutor は止めたままの断り・文言を出し続けうる形だった
final class AppUnderTestLifeRecordTests: XCTestCase {
    func testStoppedCommandOnlyWhileStopped() {
        let record = AppUnderTestLifeRecord()
        XCTAssertEqual(record.life, .notLaunched)
        XCTAssertNil(record.stoppedCommand)
        record.noteStopped(by: "removeApp")
        XCTAssertEqual(record.life, .stoppedByScenario)
        XCTAssertEqual(record.stoppedCommand, "removeApp")
        record.noteLaunched()
        XCTAssertEqual(record.life, .launched)
        XCTAssertNil(record.stoppedCommand)
    }

    /// 照会で居ると分かったら、StepExecutor から見ても止めたままではない(同じ持ち物を読む)
    func testFoundRunningClearsTheExecutorsViewToo() {
        let executor = StepExecutor(driver: FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[]]),
                                    isAndroid: true, tunables: RunTunables())
        executor.appUnderTestLife.noteStopped(by: "terminateApp")
        XCTAssertTrue(executor.appUnderTestStopped)
        XCTAssertEqual(executor.appUnderTestStoppedCommand, "terminateApp")
        executor.appUnderTestLife.noteFoundRunning()
        XCTAssertFalse(executor.appUnderTestStopped)
        XCTAssertNil(executor.appUnderTestStoppedCommand)
        XCTAssertEqual(executor.appUnderTestLife.life, .launched)
    }

    /// 起こしていない・起動済みのときの「居る」は何も変えない(起こしていないアプリを起動済みと言わない = processGone の記録の条件)
    func testFoundRunningDoesNotPromoteANeverLaunchedApp() {
        let record = AppUnderTestLifeRecord()
        record.noteFoundRunning()
        XCTAssertEqual(record.life, .notLaunched)
    }
}
