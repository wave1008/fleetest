// MultiTargetJobTracker(複数対象の run のジョブの行)の検証。
// 守るもの: ①外側が受け持ち済み(MARKED)なら作らない ②ID が無ければ自分で作って子へ ID と MARKED を継がせ、終わりに消す
// ③外側の ID があればその行を使い、終わりに消さない ④出口の安全網(終端でない行は canceled)⑤終わりの状態の読み替え

import XCTest
import FTCore
@testable import fleetest

final class MultiTargetJobTrackerTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiTargetJobTrackerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testOwnJobIsCreatedExportedAndRemoved() throws {
        let dir = tempDir()
        let env = LockedValue<[String: String]>([:])
        let tracker = try XCTUnwrap(MultiTargetJobTracker.begin(
            targets: [("A", "p"), ("B", "q")], issuer: "me", directory: dir, outerJobID: nil, outerMarked: false,
            ownerPid: ProcessInfo.processInfo.processIdentifier, setEnvironment: { k, v in env.withLock { $0[k] = v } }))
        XCTAssertTrue(tracker.ownsJob)
        XCTAssertEqual(env.withLock { $0 }, [JobMembership.jobIDKey: tracker.jobID, JobMembership.markedKey: "1"])
        let job = try XCTUnwrap(JobProgressLedger.readAll(directory: dir).first)
        XCTAssertEqual(job.runs.map(\.state), [.pending, .pending])
        XCTAssertEqual(job.title, "run")

        tracker.running(project: "A", profile: "p", machine: "local")
        tracker.running(project: "A", profile: "p", machine: "M1")
        tracker.mark(project: "A", profile: "p", state: .passed)
        let mid = try XCTUnwrap(JobProgressLedger.readAll(directory: dir).first)
        XCTAssertEqual(mid.runs[0].state, .passed)
        XCTAssertEqual(mid.runs[0].machines, ["local", "M1"])

        tracker.closeOut()
        XCTAssertTrue(JobProgressLedger.readAll(directory: dir).isEmpty)
    }

    func testOuterJobIsUsedAndKept() throws {
        let dir = tempDir()
        let outer = JobProgressLedger.begin(
            title: "e2e", ownerPid: ProcessInfo.processInfo.processIdentifier,
            runs: [JobRunEntry(project: "A", profile: "p", state: .pending),
                   JobRunEntry(project: "Z", profile: "z", state: .pending)], issuer: nil, directory: dir)
        let env = LockedValue<[String: String]>([:])
        let tracker = try XCTUnwrap(MultiTargetJobTracker.begin(
            targets: [("A", "p")], directory: dir, outerJobID: outer.jobID, outerMarked: false,
            setEnvironment: { k, v in env.withLock { $0[k] = v } }))
        XCTAssertFalse(tracker.ownsJob)
        XCTAssertEqual(env.withLock { $0 }, [JobMembership.markedKey: "1"])
        tracker.running(project: "A", profile: "p", machine: "local")
        let running = try XCTUnwrap(JobProgressLedger.readAll(directory: dir).first)
        XCTAssertEqual(running.runs[0].pid, ProcessInfo.processInfo.processIdentifier,
                       "running の行に親の pid(SIGKILL されたら監視が canceled と読む)")
        tracker.closeOut()
        let job = try XCTUnwrap(JobProgressLedger.readAll(directory: dir).first)
        XCTAssertEqual(job.runs.map(\.state), [.canceled, .pending],
                       "閉じるのは running にしたまま閉じていない自分の行だけ・外側の予定の行には触らない")
    }

    /// 外側のジョブで、自分の対象と同じ鍵の予定がこの run の後にもある(regress.py の証人)。終えた対象の後の同じ鍵の行は残す
    func testOuterJobLaterRowWithSameKeyIsKept() throws {
        let dir = tempDir()
        let outer = JobProgressLedger.begin(
            title: "regress", ownerPid: ProcessInfo.processInfo.processIdentifier,
            runs: [JobRunEntry(project: "A", profile: "p", state: .pending),
                   JobRunEntry(project: "A", profile: "p", state: .pending)], issuer: nil, directory: dir)
        let tracker = try XCTUnwrap(MultiTargetJobTracker.begin(
            targets: [("A", "p")], directory: dir, outerJobID: outer.jobID, outerMarked: false, setEnvironment: { _, _ in }))
        tracker.running(project: "A", profile: "p", machine: "local")
        tracker.mark(project: "A", profile: "p", state: .passed)
        tracker.closeOut()
        let job = try XCTUnwrap(JobProgressLedger.readAll(directory: dir).first)
        XCTAssertEqual(job.runs.map(\.state), [.passed, .pending])
    }

    func testMarkedAncestorMeansNoTracker() {
        XCTAssertNil(MultiTargetJobTracker.begin(
            targets: [("A", "p")], directory: tempDir(), outerJobID: "x", outerMarked: true, setEnvironment: { _, _ in }))
    }

    func testFinalState() {
        typealias T = MultiTargetJobTracker
        XCTAssertEqual(T.finalState(codes: [0, 0], started: true, hasUnhanded: false, interrupted: false), .passed)
        XCTAssertEqual(T.finalState(codes: [0, 1], started: true, hasUnhanded: false, interrupted: false), .failed)
        XCTAssertEqual(T.finalState(codes: [0], started: true, hasUnhanded: true, interrupted: false), .failed)
        XCTAssertEqual(T.finalState(codes: [130], started: true, hasUnhanded: true, interrupted: true), .canceled)
        XCTAssertEqual(T.finalState(codes: [0], started: true, hasUnhanded: false, interrupted: true), .passed)
        XCTAssertEqual(T.finalState(codes: [], started: false, hasUnhanded: false, interrupted: true), .canceled)
        XCTAssertEqual(T.finalState(codes: [], started: false, hasUnhanded: false, interrupted: false), .failed)
    }

    // MARK: 機械の準備中の段階

    private func ownTracker(_ dir: URL) throws -> MultiTargetJobTracker {
        try XCTUnwrap(MultiTargetJobTracker.begin(
            targets: [("A", "p"), ("B", "q")], issuer: "me", directory: dir, outerJobID: nil, outerMarked: false,
            ownerPid: ProcessInfo.processInfo.processIdentifier, setEnvironment: { _, _ in }))
    }

    func testPreparingStagesAreSetPerMachine() throws {
        let dir = tempDir()
        let tracker = try ownTracker(dir)
        for stage in JobPreparingStage.allCases {
            tracker.preparing(machine: "M1", stage: stage, project: "A", profile: "p")
            let job = try XCTUnwrap(JobProgressLedger.readAll(directory: dir).first)
            XCTAssertEqual(job.preparing["M1"], JobPreparingActivity(stage: stage, project: "A", profile: "p"))
        }
        tracker.preparing(machine: "M2", stage: .startingRun, project: "B", profile: "q")
        XCTAssertEqual(Set(try XCTUnwrap(JobProgressLedger.readAll(directory: dir).first).preparing.keys), ["M1", "M2"])
    }

    /// 対象が終端になったら、その対象の段階だけ消える(次の対象が同じ機械へ置いた段階は残る)
    func testTerminalMarkClearsOnlyThatTargetsPreparing() throws {
        let dir = tempDir()
        let tracker = try ownTracker(dir)
        tracker.running(project: "A", profile: "p", machine: "M1")
        tracker.preparing(machine: "M1", stage: .collectingResults, project: "A", profile: "p")
        tracker.preparing(machine: "M2", stage: .checkingRunner, project: "B", profile: "q")
        tracker.mark(project: "A", profile: "p", state: .passed)
        let job = try XCTUnwrap(JobProgressLedger.readAll(directory: dir).first)
        XCTAssertNil(job.preparing["M1"])
        XCTAssertEqual(job.preparing["M2"]?.project, "B")
    }

    /// 借りたジョブを閉じるとき、閉じていない自分の対象の段階も消える
    func testCloseOutClearsPreparingOfOpenTargetsInBorrowedJob() throws {
        let dir = tempDir()
        let outer = JobProgressLedger.begin(
            title: "e2e", ownerPid: ProcessInfo.processInfo.processIdentifier,
            runs: [JobRunEntry(project: "A", profile: "p", state: .pending)], issuer: nil, directory: dir)
        let tracker = try XCTUnwrap(MultiTargetJobTracker.begin(
            targets: [("A", "p")], directory: dir, outerJobID: outer.jobID, outerMarked: false, setEnvironment: { _, _ in }))
        tracker.running(project: "A", profile: "p", machine: "M1")
        tracker.preparing(machine: "M1", stage: .transferringProject, project: "A", profile: "p")
        tracker.closeOut()
        XCTAssertTrue(try XCTUnwrap(JobProgressLedger.readAll(directory: dir).first).preparing.isEmpty)
    }

    /// 子のディスパッチ側の書き手: 自分の置いた段階だけ消す(次の対象の段階は消さない)・ジョブが無ければ nil
    func testReporterClearsOnlyItsOwnActivity() throws {
        let dir = tempDir()
        let tracker = try ownTracker(dir)
        let a = try XCTUnwrap(JobPreparingReporter.fromEnvironment(
            machine: "M1", project: "A", profile: "p", jobID: tracker.jobID, directory: dir))
        let b = try XCTUnwrap(JobPreparingReporter.fromEnvironment(
            machine: "M1", project: "B", profile: "q", jobID: tracker.jobID, directory: dir))
        a.enter(.collectingResults)
        b.enter(.checkingRunner)
        a.clear()
        XCTAssertEqual(try XCTUnwrap(JobProgressLedger.readAll(directory: dir).first).preparing["M1"]?.stage, .checkingRunner)
        b.clear()
        XCTAssertTrue(try XCTUnwrap(JobProgressLedger.readAll(directory: dir).first).preparing.isEmpty)
        XCTAssertNil(JobPreparingReporter.fromEnvironment(machine: "M1", project: "A", profile: "p", jobID: nil, directory: dir))
        XCTAssertNil(JobPreparingReporter.fromEnvironment(machine: nil, project: "A", profile: "p", jobID: "x", directory: dir))
    }

    // MARK: 配線(ソース走査)

    /// RemoteRunDispatcher が5つの段階をすべて報告し、リモートの run の最初の行で消すこと
    func testDispatcherReportsEveryStageAndClearsOnRunStart() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/fleetest/RemoteRunDispatcher.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        for stage in JobPreparingStage.allCases {
            XCTAssertTrue(text.contains("preparing?.enter(.\(stage.rawValue))"),
                          "RemoteRunDispatcher が段階 \(stage.rawValue) を報告していない(run ボードの機械の行が「空き」に見える)")
        }
        XCTAssertTrue(text.contains("onRunStarted: { preparing?.clear() }"), "リモートの run が始まっても準備中の表示が残る")
        XCTAssertTrue(text.contains("runStarted.withLock") && text.contains("onRunStarted()"),
                      "最初に中継した行で onRunStarted を呼んでいない")
    }
}
