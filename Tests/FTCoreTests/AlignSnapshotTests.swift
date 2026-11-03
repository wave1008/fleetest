// AlignSnapshot の手元の計算とランナーの照会コマンドが、同じツリーに同じ答えを出すことを固定する
// (片方だけ変えると、中身が同じでもディスパッチが止まる・違っても通る)。一時リポジトリだけを触る。

import Foundation
import XCTest
import FTCore
import FTRemote

final class AlignSnapshotTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("align-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("TestProjects/P/scenarios"),
                                                withIntermediateDirectories: true)
        try write("Sources/a.swift", "let a = 1\n")
        try write("TestProjects/P/scenarios/s.swift", "let s = 1\n")
        try git(["init", "-q"])
        try git(["add", "-A"])
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "base"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    func testCleanTreeSendsHeadAndRemoteProbeAgreesOnDigest() throws {
        let local = try AlignSnapshot.localTree(repoRoot: repo)
        XCTAssertTrue(local.isClean)
        XCTAssertEqual(try AlignSnapshot.commitToSend(repoRoot: repo, local: local, issuer: "alice"), local.head)
        let probed = try probe()
        XCTAssertEqual(probed, AlignSnapshot.RemoteToolState(head: local.head, digest: local.digest,
                                                             base: local.head, snapshotIssuer: nil))
    }

    func testSnapshotCheckedOutOnTheRunnerReportsBaseIssuerAndTheSameDigest() throws {
        try write("Sources/a.swift", "let a = 2\n")
        try write("Sources/new.swift", "let n = 1\n")
        let local = try AlignSnapshot.localTree(repoRoot: repo)
        XCTAssertFalse(local.isClean)
        let snapshot = try AlignSnapshot.commitToSend(repoRoot: repo, local: local, issuer: "alice")
        XCTAssertNotEqual(snapshot, local.head)
        // 同じ中身・同じ HEAD・同じ issuer なら同じ SHA(align.sh が全機へ並列に作っても揃う)
        XCTAssertEqual(try AlignSnapshot.commitToSend(repoRoot: repo, local: local, issuer: "alice"), snapshot)
        // 本物のインデックスは触らない(未追跡のまま・変更は未ステージのまま)
        XCTAssertTrue(try git(["status", "--porcelain"]).contains("?? Sources/new.swift"))

        // ランナー役のクローンへ align と同じ ref で送り、そこで checkout する(手元の作業ツリーは触らない)
        let runner = repo.appendingPathComponent("runner-clone")
        try git(["clone", "-q", repo.path, runner.path])
        try git(["push", "-q", "--force", runner.path, "\(snapshot):\(AlignSnapshot.pushRef)"])
        try git(["-C", runner.path, "checkout", "-q", "--detach", snapshot])
        let probed = try probe(at: runner)
        XCTAssertEqual(probed, AlignSnapshot.RemoteToolState(head: snapshot, digest: local.digest,
                                                             base: local.head, snapshotIssuer: "alice"))
    }

    func testOnlyTestProjectsChangesKeepTheDigest() throws {
        let before = try AlignSnapshot.localTree(repoRoot: repo)
        try write("TestProjects/P/scenarios/s.swift", "let s = 2\n")
        let after = try AlignSnapshot.localTree(repoRoot: repo)
        XCTAssertFalse(after.isClean)
        XCTAssertEqual(after.digest, before.digest)
        try write("Sources/a.swift", "let a = 3\n")
        XCTAssertNotEqual(try AlignSnapshot.localTree(repoRoot: repo).digest, before.digest)
    }

    func testProbeOfMissingCloneReadsAsNil() throws {
        let missing = repo.appendingPathComponent("no-such-clone").path
        for shell in Self.shells {
            let result = try Shell.runData([shell, "-c",
                AlignSnapshot.remoteProbeCommand(quotedToolRoot: "\"\(missing)\"")])
            let lines = String(decoding: result.data, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
            XCTAssertEqual(lines, ["-", "-", "-", "-"], shell)
            XCTAssertNil(AlignSnapshot.parseRemoteProbe(lines))
        }
    }

    // MARK: - helpers

    /// ランナーのログインシェルは zsh(`echo -` が空行になる)。sh と zsh の両方で同じ4行を要る
    private static let shells = ["/bin/sh", "/bin/zsh"]

    private func probe(at clone: URL? = nil) throws -> AlignSnapshot.RemoteToolState? {
        var parsed: [AlignSnapshot.RemoteToolState?] = []
        for shell in Self.shells {
            let result = try Shell.runData([shell, "-c",
                AlignSnapshot.remoteProbeCommand(quotedToolRoot: "\"\((clone ?? repo).path)\"")])
            XCTAssertEqual(result.status, 0)
            // 空の要素を落とさない(空行が出たらここで数が合わず落ちる)
            let lines = String(decoding: result.data, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
            XCTAssertEqual(lines.count, 4, "\(shell): the probe must always print 4 lines: \(lines)")
            XCTAssertFalse(lines.contains(where: \.isEmpty), "\(shell) printed an empty line: \(lines)")
            parsed.append(AlignSnapshot.parseRemoteProbe(lines))
        }
        XCTAssertEqual(parsed.first, parsed.last)
        return parsed.first ?? nil
    }

    private func write(_ relative: String, _ content: String) throws {
        try content.write(to: repo.appendingPathComponent(relative), atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func git(_ args: [String]) throws -> String {
        let result = try Shell.run(["git", "-C", repo.path] + args)
        XCTAssertEqual(result.status, 0, "git \(args): \(result.output)")
        return result.output
    }
}
