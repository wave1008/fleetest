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
}
