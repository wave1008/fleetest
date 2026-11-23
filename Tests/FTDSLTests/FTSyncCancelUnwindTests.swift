// FTSync.run の時間切れの後始末。cancel の後、op が止まり切るまで(上限つきで)待ってから戻る。待たずに戻ると、
// 止まり切る前の op が後片付け(afterEach)のステップと同じ StepExecutor の状態を同時に書く

import XCTest
@testable import FTDSL
import FTCore

final class FTSyncCancelUnwindTests: XCTestCase {
    /// cancel を見ない op(子プロセスの照会の形 = ブロッキング)でも、戻る前に走り切るのを待つ
    func testTimedOutOperationHasFinishedWhenRunReturns() {
        let finished = LockedValue(false)
        let opEndedAt = LockedValue<Date?>(nil)
        let report = FTSync.TimeoutReport()
        let value = FTSync.run(timeout: 0.05, timeoutReport: report, unwindGrace: 3) { () -> Int in
            usleep(300_000)  // cancel を見ないブロッキング(子プロセスの照会の形)
            opEndedAt.withLock { $0 = Date() }
            finished.withLock { $0 = true }
            return 1
        }
        XCTAssertNil(value, "打ち切りの意味は変えない(値は捨てる)")
        XCTAssertTrue(finished.withLock { $0 }, "op が止まり切る前に戻った = 次のステップと重なる")
        XCTAssertFalse(report.unwindOverran)
        // 打ち切りを決めた時刻は待つ前 = op が終わるより前(失敗の時刻 `at` を巻き戻りの待ちのぶんずらさない)
        guard let decided = report.decidedAt, let ended = opEndedAt.withLock({ $0 }) else {
            return XCTFail("打ち切りを決めた時刻か op の終わりが記録されていない")
        }
        XCTAssertLessThan(decided, ended, "待った後の時刻を採っている")
    }

    /// 上限まで待っても戻らなければ諦めて戻り、その事実を持ち帰る(DSL スレッドを止め続けない)
    func testGivesUpAfterTheGraceAndReportsTheOverlap() {
        let finished = LockedValue(false)
        let report = FTSync.TimeoutReport()
        let value = FTSync.run(timeout: 0.05, timeoutReport: report, unwindGrace: 0.1) { () -> Int in
            usleep(1_000_000)
            finished.withLock { $0 = true }
            return 1
        }
        XCTAssertNil(value)
        XCTAssertFalse(finished.withLock { $0 })
        XCTAssertTrue(report.unwindOverran, "重なりうることを失敗文で言えない")
    }

    /// 時間切れでなければ待ちも報告も無い
    func testNoReportWithoutATimeout() {
        let report = FTSync.TimeoutReport()
        XCTAssertEqual(FTSync.run(timeout: 5, timeoutReport: report) { 7 }, 7)
        XCTAssertFalse(report.unwindOverran)
    }

    /// 失敗文は、止まり切らなかった回だけ後続と重なりうることを言う
    func testTimedOutMessageMentionsTheOverlapOnlyWhenItOverran() {
        let report = FTSync.TimeoutReport()
        XCTAssertFalse(FTSync.timedOutMessage(report).contains("overlapped"))
        report.unwindOverran = true
        XCTAssertTrue(FTSync.timedOutMessage(report).contains("may have overlapped"))
    }

    /// 子は親から受けた RunTunables の値を使う(コマンドの上限と止まり切る待ちの両方。片方だけ写すと親の監視の上限と食い違う)
    func testApplyCopiesBothLimitsFromTheTunables() {
        let saved = (FTSync.commandTimeout, FTSync.cancelUnwindGraceSeconds)
        defer { FTSync.commandTimeout = saved.0; FTSync.cancelUnwindGraceSeconds = saved.1 }
        FTSync.apply(RunTunables(commandTimeout: 33, commandCancelUnwindSeconds: 2))
        XCTAssertEqual(FTSync.commandTimeout, 33)
        XCTAssertEqual(FTSync.cancelUnwindGraceSeconds, 2)
    }
}
