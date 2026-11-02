// OI-98: ビルド中の中断。2回目の中断で exit(143) して片付けとロックの解放を飛ばさない。
// `forceExit` の差し替え口でプロセスごと終わらずに縛る。BuildAbort はプロセス全体の状態なので、1テストずつ戻す。

import XCTest
import FTCore
@testable import fleetest

final class RunInterruptStateBuildAbortTests: XCTestCase {
    override func setUp() { BuildAbort.resetForTesting() }
    override func tearDown() { BuildAbort.resetForTesting() }

    private final class Exits: @unchecked Sendable {
        private let lock = NSLock()
        private var codes: [Int32] = []
        func record(_ c: Int32) { lock.lock(); codes.append(c); lock.unlock() }
        var all: [Int32] { lock.lock(); defer { lock.unlock() }; return codes }
    }

    private final class StatusBox: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int32?
        func set(_ x: Int32?) { lock.lock(); status = x; lock.unlock() }
        var value: Int32? { lock.lock(); defer { lock.unlock() }; return status }
    }

    private final class Trace: @unchecked Sendable { var steps: [String] = [] }

    private func startBuild(_ script: String) -> (done: DispatchSemaphore, status: StatusBox) {
        let done = DispatchSemaphore(value: 0)
        let box = StatusBox()
        Thread.detachNewThread {
            let r = try? Shell.run(["sh", "-c", script], abortable: true)
            box.set(r?.status)
            done.signal()
        }
        return (done, box)
    }

    /// ビルドが起きた印のファイルを待つ(印の後の 0.2 秒で Shell.run の登録が済む)
    private func waitUntilStarted(marker: String) {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: marker) { usleep(200_000); return }
            usleep(50_000)
        }
        XCTFail("ビルドが起動しない")
    }

    private func newMarker() -> String { NSTemporaryDirectory() + "ft-oi98-\(UUID().uuidString)" }

    /// 破ると落ちる: abortAll を requestStop から外すと、ビルドが走りきって待ちが尽きる
    func testFirstInterruptStopsARunningBuildWithoutExiting() {
        let marker = newMarker()
        defer { try? FileManager.default.removeItem(atPath: marker) }
        let exits = Exits()
        let state = RunInterruptState(recorder: nil, forceExit: { exits.record($0) })
        let build = startBuild("touch \(marker); sleep 30")
        waitUntilStarted(marker: marker)
        state.requestStop()
        XCTAssertEqual(build.done.wait(timeout: .now() + 10), .success, "1回目の中断でビルドが止まらない")
        XCTAssertNotEqual(build.status.value, 0)
        XCTAssertEqual(exits.all, [])
    }

    /// 破ると落ちる: `signalledBuilds > 0` の分岐を外すと 143 が記録される(片付けが飛ぶ形)
    func testSecondInterruptDuringABuildKillsItAndDoesNotForceExit() {
        let marker = newMarker()
        defer { try? FileManager.default.removeItem(atPath: marker) }
        let exits = Exits()
        let state = RunInterruptState(recorder: nil, forceExit: { exits.record($0) })
        // SIGTERM を無視するビルド(1回目では止まらず、2回目の SIGKILL で止まる)
        let build = startBuild("trap '' TERM; touch \(marker); while :; do sleep 1; done")
        waitUntilStarted(marker: marker)
        state.requestStop()
        XCTAssertEqual(build.done.wait(timeout: .now() + 1), .timedOut, "前提: SIGTERM を無視するビルドが残っている")
        state.requestStop()
        XCTAssertEqual(build.done.wait(timeout: .now() + 10), .success, "2回目の中断で SIGKILL まで上がらない")
        XCTAssertEqual(exits.all, [], "ビルド中の2回目で強制終了すると片付けとロックの解放が飛ぶ")
    }

    /// ビルドが無い2回目は従来どおり強制終了(人が抜ける最終手段を残す)
    func testSecondInterruptWithoutABuildStillForceExits() {
        let exits = Exits()
        let state = RunInterruptState(recorder: nil, forceExit: { exits.record($0) })
        state.requestStop()
        state.requestStop()
        XCTAssertEqual(exits.all, [143])
    }

    /// 中断済みの後に起こすビルドは起こした直後に止まる(供給の再試行が撃ち直さない)
    func testABuildStartedAfterTheInterruptIsStoppedImmediately() throws {
        let state = RunInterruptState(recorder: nil, forceExit: { _ in })
        state.requestStop()
        let started = Date()
        let r = try Shell.run(["sh", "-c", "sleep 30"], abortable: true)
        XCTAssertNotEqual(r.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    /// 出口: ビルドが中断で落ちて本体が投げても、片付けとロックの解放が通る
    func testExitGuardCleansUpWhenTheBuildIsInterrupted() async {
        let marker = newMarker()
        defer { try? FileManager.default.removeItem(atPath: marker) }
        let state = RunInterruptState(recorder: nil, forceExit: { _ in })
        let trace = Trace()
        do {
            try await RunExitGuard.run(log: { _ in }) { exit in
                exit.close = { trace.steps.append("close") }
                exit.dispatchLock = LocalDispatchLock.Holder { trace.steps.append("lock") }
                let build = startBuild("touch \(marker); sleep 30")
                waitUntilStarted(marker: marker)
                state.requestStop()
                XCTAssertEqual(build.done.wait(timeout: .now() + 10), .success)
                throw ScenarioHostError.buildInterrupted
            }
            XCTFail("投げ直していない")
        } catch {}
        XCTAssertEqual(trace.steps, ["close", "lock"])
    }
}
