// JobProgressLedger(run ボードのジョブ台帳)の検証。
// 守るもの: ①行の印付けの規則(running は pending 優先・無ければ末尾に足す・machines は重複なし)
// ②生存判定は ownerPid + startedAt ③壊れた JSON は1件飛ばす ④sweep は死んだ持ち主のぶんだけ消す
// ⑤並行 update が flock の下で欠けない ⑥置き場はリテラルで固定 ⑦ID はパスの部品にできる形だけ通す。

import XCTest
@testable import FTCore

final class JobProgressLedgerTests: XCTestCase {
    private static let unknownStart: @Sendable (Int32) -> Date? = { _ in nil }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("JobProgressLedgerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func pending(_ project: String, _ profile: String) -> JobRunEntry {
        JobRunEntry(project: project, profile: profile, state: .pending)
    }

    func testDirectoryIsPinned() {
        let home = URL(fileURLWithPath: "/h")
        XCTAssertEqual(JobProgressLedger.directory(home: home).path, "/h/.fleetest/jobs")
    }

    // MARK: mark の規則

    func testRunningPrefersPendingRowOverRunningRow() {
        var runs = [JobRunEntry(project: "A", profile: "p", state: .running), pending("A", "p")]
        JobRunMarking.mark(runs: &runs, project: "A", profile: "p", state: .running, machine: "m1")
        XCTAssertEqual(runs.map(\.state), [.running, .running])
        XCTAssertEqual(runs[1].machines, ["m1"], "pending の行を先に running にする")
        XCTAssertEqual(runs[0].machines, [])
    }

    func testRunningFallsBackToRunningRowAndDedupesMachines() {
        var runs = [JobRunEntry(project: "A", profile: "p", state: .running, machines: ["local"])]
        JobRunMarking.mark(runs: &runs, project: "A", profile: "p", state: .running, machine: "M1")
        JobRunMarking.mark(runs: &runs, project: "A", profile: "p", state: .running, machine: "M1")
        JobRunMarking.mark(runs: &runs, project: "A", profile: "p", state: .running, machine: "local")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].machines, ["local", "M1"])
    }

    func testTerminalMarksFirstNonTerminalRowAndClearsPid() {
        var runs = [JobRunEntry(project: "A", profile: "p", state: .passed), pending("B", "p"),
                    JobRunEntry(project: "A", profile: "p", state: .running, pid: 42), pending("A", "p")]
        JobRunMarking.mark(runs: &runs, project: "A", profile: "p", state: .failed)
        XCTAssertEqual(runs.map(\.state), [.passed, .pending, .failed, .pending])
        XCTAssertNil(runs[2].pid)
    }

    func testUnknownRunIsAppendedAtTheEnd() {
        var runs = [pending("A", "p")]
        JobRunMarking.mark(runs: &runs, project: "B", profile: "q", state: .running, machine: "local", pid: 7)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[1], JobRunEntry(project: "B", profile: "q", state: .running, machines: ["local"], pid: 7))
        // 終端でない行が無い同じ run の終端は、もう1行足される(宣言していない run も事実として載る)
        var done = [JobRunEntry(project: "A", profile: "p", state: .passed)]
        JobRunMarking.mark(runs: &done, project: "A", profile: "p", state: .failed)
        XCTAssertEqual(done.map(\.state), [.passed, .failed])
    }

    // MARK: 台帳

    func testBeginUpdateReadAllRoundTrip() {
        let dir = tempDir()
        let record = JobProgressLedger.begin(
            title: "t", ownerPid: 100, runs: [pending("A", "p")], issuer: "me", directory: dir,
            isAlive: { _ in true }, startTime: Self.unknownStart)
        JobProgressLedger.mark(jobID: record.jobID, project: "A", profile: "p", state: .running, pid: 100, directory: dir)
        let read = JobProgressLedger.readAll(directory: dir, isAlive: { _ in true }, startTime: Self.unknownStart)
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read[0].title, "t")
        XCTAssertEqual(read[0].runs[0].state, .running)
        XCTAssertEqual(read[0].runs[0].pid, 100)
    }

    func testUpdateOfMissingJobDoesNothingAndCreatesNoFiles() {
        let dir = tempDir()
        JobProgressLedger.mark(jobID: UUID().uuidString, project: "A", profile: "p", state: .running, directory: dir)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.count, 0)
    }

    func testReadAllSkipsDeadOwnerAndStartedAfterRecordAndBrokenJSON() throws {
        let dir = tempDir()
        let alive = JobProgressLedger.begin(title: "alive", ownerPid: 10, runs: [], issuer: nil, directory: dir,
                                            isAlive: { _ in true }, startTime: Self.unknownStart)
        _ = JobProgressLedger.begin(title: "dead", ownerPid: 11, runs: [], issuer: nil, directory: dir,
                                    isAlive: { _ in true }, startTime: Self.unknownStart)
        _ = JobProgressLedger.begin(title: "reused", ownerPid: 12, runs: [], issuer: nil, directory: dir,
                                    isAlive: { _ in true }, startTime: Self.unknownStart)
        try "{ broken".write(to: dir.appendingPathComponent("x.json"), atomically: true, encoding: .utf8)
        let read = JobProgressLedger.readAll(
            directory: dir, isAlive: { $0 != 11 }, startTime: { $0 == 12 ? Date().addingTimeInterval(3600) : nil })
        XCTAssertEqual(read.map(\.jobID), [alive.jobID])
    }

    func testSweepRemovesOnlyDeadOwnersAndOrphanLocks() throws {
        let dir = tempDir()
        let keep = JobProgressLedger.begin(title: "keep", ownerPid: 10, runs: [], issuer: nil, directory: dir,
                                           isAlive: { _ in true }, startTime: Self.unknownStart)
        let gone = JobProgressLedger.begin(title: "gone", ownerPid: 11, runs: [], issuer: nil, directory: dir,
                                           isAlive: { _ in true }, startTime: Self.unknownStart)
        JobProgressLedger.mark(jobID: gone.jobID, project: "A", profile: "p", state: .running, directory: dir)
        JobProgressLedger.mark(jobID: keep.jobID, project: "A", profile: "p", state: .running, directory: dir)
        try "x".write(to: dir.appendingPathComponent("orphan.lock"), atomically: true, encoding: .utf8)
        try "keepme".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        JobProgressLedger.sweep(directory: dir, isAlive: { $0 != 11 }, startTime: Self.unknownStart)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertEqual(names, ["\(keep.jobID).json", "\(keep.jobID).lock", "notes.txt"])
    }

    func testBeginSweepsDeadOwners() {
        let dir = tempDir()
        _ = JobProgressLedger.begin(title: "old", ownerPid: 11, runs: [], issuer: nil, directory: dir,
                                    isAlive: { _ in true }, startTime: Self.unknownStart)
        _ = JobProgressLedger.begin(title: "new", ownerPid: 10, runs: [], issuer: nil, directory: dir,
                                    isAlive: { $0 != 11 }, startTime: Self.unknownStart)
        let read = JobProgressLedger.readAll(directory: dir, isAlive: { _ in true }, startTime: Self.unknownStart)
        XCTAssertEqual(read.map(\.title), ["new"])
    }

    func testConcurrentUpdatesAreNotLost() {
        let dir = tempDir()
        let record = JobProgressLedger.begin(title: "c", ownerPid: 10, runs: [], issuer: nil, directory: dir,
                                             isAlive: { _ in true }, startTime: Self.unknownStart)
        let count = 40
        DispatchQueue.concurrentPerform(iterations: count) { i in
            JobProgressLedger.mark(jobID: record.jobID, project: "P\(i)", profile: "p", state: .passed, directory: dir)
        }
        let read = JobProgressLedger.readAll(directory: dir, isAlive: { _ in true }, startTime: Self.unknownStart)
        XCTAssertEqual(read.first?.runs.count, count, "flock が無いと read-modify-write が互いの行を消す")
    }

    func testRemoveDeletesJsonAndLock() {
        let dir = tempDir()
        let record = JobProgressLedger.begin(title: "r", ownerPid: 10, runs: [], issuer: nil, directory: dir,
                                             isAlive: { _ in true }, startTime: Self.unknownStart)
        JobProgressLedger.mark(jobID: record.jobID, project: "A", profile: "p", state: .running, directory: dir)
        JobProgressLedger.remove(jobID: record.jobID, directory: dir)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.count, 0)
    }

    func testIDValidationRejectsPathParts() {
        XCTAssertTrue(JobProgressLedger.isValidID(UUID().uuidString))
        for bad in ["", "../x", "a/b", ".hidden", "a b"] { XCTAssertFalse(JobProgressLedger.isValidID(bad), bad) }
    }
}
