// JobMembership(run が自動でジョブの行を受け持つ)の検証。
// 守るもの: ①FT_JOB_MARKED(祖先が受け持ち済み)があると claim しない ②ID が無ければ何もしない
// ③終了コード → 状態(0 / 130 / その他) ④台帳が無ければ黙って何もしない ⑤claim していなければ finish は何もしない

import XCTest
@testable import FTCore

final class JobMembershipTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("JobMembershipTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeJob(_ dir: URL) -> String {
        JobProgressLedger.begin(
            title: "t", ownerPid: ProcessInfo.processInfo.processIdentifier,
            runs: [JobRunEntry(project: "A", profile: "p", state: .pending)], issuer: nil, directory: dir).jobID
    }

    private func read(_ dir: URL) -> [JobRunEntry] {
        JobProgressLedger.readAll(directory: dir).first?.runs ?? []
    }

    func testExitCodeMapping() {
        XCTAssertEqual(JobMembership.state(forExitCode: 0), .passed)
        XCTAssertEqual(JobMembership.state(forExitCode: 130), .canceled)
        XCTAssertEqual(JobMembership.state(forExitCode: 1), .failed)
        XCTAssertEqual(JobMembership.state(forExitCode: 64), .failed)
    }

    func testClaimMarksRunningWithPidAndSetsMarkerThenFinishWritesResult() {
        let dir = tempDir()
        let id = makeJob(dir)
        let marked = LockedValue(false)
        let claim = JobMembership.claim(project: "A", profile: "p", jobID: id, alreadyMarked: false, pid: 4242,
                                        directory: dir, setMarked: { marked.withLock { $0 = true } })
        XCTAssertNotNil(claim)
        XCTAssertTrue(marked.withLock { $0 })
        XCTAssertEqual(read(dir), [JobRunEntry(project: "A", profile: "p", state: .running, pid: 4242)])
        JobMembership.finish(exitCode: 0)
        XCTAssertEqual(read(dir), [JobRunEntry(project: "A", profile: "p", state: .passed)])
        JobMembership.finish(exitCode: 1)
        XCTAssertEqual(read(dir).first?.state, .passed, "2回目の finish は何もしない")
    }

    func testFinishWithNonZeroAndInterruptCodes() {
        for (code, expected) in [(Int32(1), JobRunState.failed), (130, .canceled)] {
            let dir = tempDir()
            let id = makeJob(dir)
            JobMembership.claim(project: "A", profile: "p", jobID: id, alreadyMarked: false, pid: 1,
                                directory: dir, setMarked: {})
            JobMembership.finish(exitCode: code)
            XCTAssertEqual(read(dir).first?.state, expected)
        }
    }

    /// 中断した run は失敗が無ければ exit 0・あれば 1 で終わる。中断の印があれば終了コードより先に canceled
    func testInterruptedRunIsCanceledWhateverTheExitCode() {
        for code in [Int32(0), 1] {
            let dir = tempDir()
            let id = makeJob(dir)
            JobMembership.claim(project: "A", profile: "p", jobID: id, alreadyMarked: false, pid: 1,
                                directory: dir, setMarked: {})
            JobMembership.noteInterrupted()
            JobMembership.finish(exitCode: code)
            XCTAssertEqual(read(dir).first?.state, .canceled, "exit \(code)")
        }
        // 受け持つ前の印は持ち越さない
        let dir = tempDir()
        let id = makeJob(dir)
        JobMembership.noteInterrupted()
        JobMembership.claim(project: "A", profile: "p", jobID: id, alreadyMarked: false, pid: 1,
                            directory: dir, setMarked: {})
        JobMembership.finish(exitCode: 0)
        XCTAssertEqual(read(dir).first?.state, .passed)
    }

    func testMarkedAncestorMeansNoClaim() {
        let dir = tempDir()
        let id = makeJob(dir)
        let marked = LockedValue(false)
        let claim = JobMembership.claim(project: "A", profile: "p", jobID: id, alreadyMarked: true, pid: 1,
                                        directory: dir, setMarked: { marked.withLock { $0 = true } })
        XCTAssertNil(claim)
        XCTAssertFalse(marked.withLock { $0 })
        JobMembership.finish(exitCode: 0)
        XCTAssertEqual(read(dir).first?.state, .pending, "受け持っていない run は行を触らない")
    }

    func testNoJobIDMeansNoClaim() {
        let dir = tempDir()
        XCTAssertNil(JobMembership.claim(project: "A", profile: "p", jobID: nil, alreadyMarked: false, pid: 1,
                                         directory: dir, setMarked: {}))
    }

    func testMissingLedgerFileIsSilent() {
        let dir = tempDir()
        let claim = JobMembership.claim(project: "A", profile: "p", jobID: UUID().uuidString,
                                        alreadyMarked: false, pid: 1, directory: dir, setMarked: {})
        XCTAssertNotNil(claim)
        JobMembership.finish(exitCode: 0)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.count, 0)
    }
}
