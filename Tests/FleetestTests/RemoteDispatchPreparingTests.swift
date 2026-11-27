// ディスパッチが書く機械の準備中の段階(JobPreparingReporter)の後始末と開始行の判定。
// 守るもの: ①どの出口でも自分の段階を消す(`performDispatch` 冒頭の defer の1箇所)②他の run の待機列で待つ間は
// waitingForRunner を出し、取得後に checkingRunner が置き換える ③消すのはリモートの run の開始行だけ(警告行では消さない)
// ④分担の run で先に終わった機械の段階は、まだ走っている別機械を待たずに消える

import XCTest
import FTCore
import FTRemote

final class RemoteDispatchPreparingTests: XCTestCase {
    private func dispatcherBody() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/fleetest/RemoteRunDispatcher.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "private func performDispatch("))
        let end = try XCTUnwrap(text.range(of: "// MARK: - 0. レイアウト解決", range: start.upperBound..<text.endIndex))
        return String(text[start.upperBound..<end.lowerBound])
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteDispatchPreparingTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 段階を置いた直後に defer で消す宣言が、最初の `try`(resolveLayout・照合・ロック・転送のどれも)より前にある。
    /// 消す呼び出しはほかに無い(出口ごとに書くと、書き忘れた出口が残る)
    func testClearIsGuaranteedByOneDeferBeforeTheFirstThrowingCall() throws {
        let body = try dispatcherBody()
        let deferAt = try XCTUnwrap(body.range(of: "defer { preparing?.clear() }"), "全出口で消す defer が無い")
        let firstTry = try XCTUnwrap(body.range(of: "try resolveLayout()"))
        XCTAssertLessThan(deferAt.lowerBound, firstTry.lowerBound, "defer より前に throw しうる呼び出しがある")
        XCTAssertEqual(body.components(separatedBy: "preparing?.clear()").count - 1, 2,
                       "消す呼び出しは defer と onRunStarted の2箇所だけ(出口ごとの clear を足さない)")
        XCTAssertTrue(body.contains("onRunStarted: { preparing?.clear() }"))
    }

    func testLockWaitStageIsSetBeforeAcquisitionAndReplacedAfterIt() throws {
        let body = try dispatcherBody()
        let wait = try XCTUnwrap(body.range(of: "preparing?.enter(.waitingForRunner)"))
        let acquire = try XCTUnwrap(body.range(of: "try acquireDispatchLock("))
        let checking = try XCTUnwrap(body.range(of: "preparing?.enter(.checkingRunner)", range: acquire.upperBound..<body.endIndex),
                                     "取得後に待ちの段階を置き換えていない")
        let transfer = try XCTUnwrap(body.range(of: "preparing?.enter(.transferringProject)"))
        XCTAssertLessThan(wait.lowerBound, acquire.lowerBound)
        XCTAssertLessThan(checking.lowerBound, transfer.lowerBound)
    }

    func testRunStartMarkerIgnoresWarningsAndBinaryMissingLines() {
        for line in ["Warning: Permanently added 'm1' (ED25519) to the list of known hosts.",
                     "==> the remote fleetest binary is missing — build it on the remote first",
                     "{\"kind\":\"dispatchWaiting\",\"seconds\":3}", "", "→ Using 2 of 3 device(s)"] {
            XCTAssertFalse(RemoteRelay.isRunStartLine(line), line)
        }
        XCTAssertTrue(RemoteRelay.isRunStartLine("{\"kind\":\"runStarted\",\"total\":4}"))
        XCTAssertTrue(RemoteRelay.isRunStartLine("🚀 Starting with 2 Android worker(s)\r"))
        XCTAssertTrue(RemoteRelay.isRunStartLine("🚀 Starting (iOS joins once bridge provisioning finishes)"))
    }

    func testWaitingForRunnerIsAKnownStageAndRoundTrips() throws {
        XCTAssertTrue(JobPreparingStage.allCases.contains(.waitingForRunner))
        XCTAssertEqual(JobPreparingStage.waitingForRunner.rawValue, "waitingForRunner")
        let dir = tempDir()
        let job = JobProgressLedger.begin(title: "t", ownerPid: ProcessInfo.processInfo.processIdentifier,
                                          runs: [], issuer: nil, directory: dir)
        let reporter = try XCTUnwrap(JobPreparingReporter.fromEnvironment(
            machine: "M1", project: "A", profile: "p", jobID: job.jobID, directory: dir))
        reporter.enter(.waitingForRunner)
        XCTAssertEqual(JobProgressLedger.readAll(directory: dir).first?.preparing["M1"]?.stage, .waitingForRunner)
        reporter.enter(.checkingRunner)
        XCTAssertEqual(JobProgressLedger.readAll(directory: dir).first?.preparing["M1"]?.stage, .checkingRunner)
    }

    /// 1つの対象を機械に分けた run: 先に終わった機械の子が消すと、走っている別の機械の段階は残り、終わった機械には残らない
    func testSplitTargetEarlyMachineIsClearedWhileAnotherStillRuns() throws {
        let dir = tempDir()
        let job = JobProgressLedger.begin(title: "t", ownerPid: ProcessInfo.processInfo.processIdentifier,
                                          runs: [], issuer: nil, directory: dir)
        let m1 = try XCTUnwrap(JobPreparingReporter.fromEnvironment(
            machine: "M1", project: "A", profile: "p", jobID: job.jobID, directory: dir))
        let m2 = try XCTUnwrap(JobPreparingReporter.fromEnvironment(
            machine: "M2", project: "A", profile: "p", jobID: job.jobID, directory: dir))
        m1.enter(.collectingResults)
        m2.enter(.startingRun)
        m1.clear()   // M1 のディスパッチの終わり(defer)
        let preparing = try XCTUnwrap(JobProgressLedger.readAll(directory: dir).first).preparing
        XCTAssertNil(preparing["M1"], "先に終わった機械が、対象全体の終わりまで回収中のまま残る")
        XCTAssertEqual(preparing["M2"]?.stage, .startingRun)
    }
}
