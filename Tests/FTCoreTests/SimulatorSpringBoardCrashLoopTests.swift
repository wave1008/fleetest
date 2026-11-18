// SpringBoard が落ち続けているかの判定(`SimulatorSpringBoard.crashLoopVerdict`)。読みの形は 11/19 に開いた iPhone Duo で採った実物
import XCTest
@testable import FTCore

final class SimulatorSpringBoardCrashLoopTests: XCTestCase {

    private typealias R = SimulatorSpringBoard.Reading

    func testParsesTheSpringBoardLineOfLaunchctlList() {
        let output = "PID\tStatus\tLabel\n123\t0\tcom.apple.backboardd\n61929\t0\tcom.apple.SpringBoard\n-\t0\tcom.apple.SpringBoardSettings\n"
        XCTAssertEqual(SimulatorSpringBoard.parse(launchctlList: output), R(pid: 61929, lastExit: 0))
        XCTAssertEqual(SimulatorSpringBoard.parse(launchctlList: "-\t-5\tcom.apple.SpringBoard\n"), R(pid: nil, lastExit: -5))
        XCTAssertNil(SimulatorSpringBoard.parse(launchctlList: "-\t0\tcom.apple.SpringBoardSettings\n"))
    }

    /// 実測の形: 約 17 秒おきに pid が変わり、前回の終了状態は毎回 -5
    func testRestartingEveryFewSecondsWithAbnormalExitIsCrashing() {
        let readings: [R?] = [R(pid: 67839, lastExit: -5), R(pid: 67839, lastExit: -5), R(pid: 68581, lastExit: -5),
                              nil, R(pid: 69359, lastExit: -5)]
        XCTAssertEqual(SimulatorSpringBoard.crashLoopVerdict(readings), .crashing(restarts: 2, lastExit: -5))
        XCTAssertTrue(SimulatorSpringBoard.crashLoopVerdict(readings).isUnusable)
    }

    /// 1回落ちて起き直しただけ(意図した起こし直しも同じ形)は止めない
    func testASingleRestartIsHealthy() {
        let readings: [R?] = [R(pid: 1, lastExit: -9), R(pid: 2, lastExit: -9), R(pid: 2, lastExit: -9)]
        XCTAssertEqual(SimulatorSpringBoard.crashLoopVerdict(readings), .healthy)
    }

    func testStoppedAfterAnAbnormalExitIsUnusable() {
        XCTAssertEqual(SimulatorSpringBoard.crashLoopVerdict([R(pid: nil, lastExit: -5), R(pid: nil, lastExit: -5)]),
                       .stopped(lastExit: -5))
    }

    func testNormalExitStatusIsHealthyEvenIfThePidChanged() {
        XCTAssertEqual(SimulatorSpringBoard.crashLoopVerdict([R(pid: 1, lastExit: 0), R(pid: 2, lastExit: 0), R(pid: 3, lastExit: 0)]),
                       .healthy)
    }

    /// 読めなかったときは止めない(材料なし)
    func testNothingReadIsUnreadableAndNotUnusable() {
        XCTAssertEqual(SimulatorSpringBoard.crashLoopVerdict([nil, nil]), .unreadable)
        XCTAssertFalse(SimulatorSpringBoard.CrashLoopVerdict.unreadable.isUnusable)
    }

    /// 落ちたことの無い台は窓を払わない(1回読んで返る)
    func testAHealthyFirstReadingReturnsWithoutSampling() async {
        let calls = LockedValue(0)
        let watched = LockedValue(false)
        let verdict = await SimulatorSpringBoard.probeCrashLoop(udid: "X", reader: { _ in
            calls.withLock { $0 += 1 }
            return R(pid: 10, lastExit: 0)
        }, onWatch: { _ in watched.withLock { $0 = true } })
        XCTAssertEqual(verdict, .healthy)
        XCTAssertEqual(calls.withLock { $0 }, 1)
        XCTAssertFalse(watched.withLock { $0 })
    }

    /// 窓の途中で取り消されたら判定しない(落ち続けの最中の1回の「pid 無し」を止まったままと読まない)
    func testCancelledWatchIsUnreadable() async {
        let task = Task { await SimulatorSpringBoard.probeCrashLoop(udid: "X", reader: { _ in R(pid: nil, lastExit: -5) }) }
        task.cancel()
        let verdict = await task.value
        XCTAssertEqual(verdict, .unreadable)
    }

    func testWindowConstantsArePinned() {
        XCTAssertEqual(SimulatorSpringBoard.crashLoopWindowSeconds, 45)
        XCTAssertEqual(SimulatorSpringBoard.crashLoopIntervalSeconds, 3)
        XCTAssertEqual(SimulatorSpringBoard.crashLoopMinRestarts, 2)
    }
}
