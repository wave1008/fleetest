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
        let local = try AlignSnapshot.localTree(repoRoot: repo, includeTestProjects: true)
        XCTAssertTrue(local.isClean)
        XCTAssertEqual(try AlignSnapshot.commitToSend(repoRoot: repo, local: local, issuer: "alice"), local.head)
        try recordBuild(at: repo, digest: local.digest)
        let probed = try probe()
        XCTAssertEqual(probed, AlignSnapshot.RemoteToolState(head: local.head, digest: local.digest,
                                                             base: local.head, snapshotIssuer: nil, built: true))
    }

    func testSnapshotCheckedOutOnTheRunnerReportsBaseIssuerAndTheSameDigest() throws {
        try write("Sources/a.swift", "let a = 2\n")
        try write("Sources/new.swift", "let n = 1\n")
        let local = try AlignSnapshot.localTree(repoRoot: repo, includeTestProjects: true)
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
        try recordBuild(at: runner, digest: local.digest)
        let probed = try probe(at: runner)
        XCTAssertEqual(probed, AlignSnapshot.RemoteToolState(head: snapshot, digest: local.digest,
                                                             base: local.head, snapshotIssuer: "alice", built: true))
    }

    func testOnlyTestProjectsChangesKeepTheDigest() throws {
        let before = try AlignSnapshot.localTree(repoRoot: repo, includeTestProjects: true)
        try write("TestProjects/P/scenarios/s.swift", "let s = 2\n")
        let after = try AlignSnapshot.localTree(repoRoot: repo, includeTestProjects: true)
        XCTAssertFalse(after.isClean)
        XCTAssertEqual(after.digest, before.digest)
        try write("Sources/a.swift", "let a = 3\n")
        XCTAssertNotEqual(try AlignSnapshot.localTree(repoRoot: repo, includeTestProjects: true).digest, before.digest)
    }

    /// 要約が手元と一致していても、成功したビルドの記録が無い・別の要約なら `built == false`(沈黙の誤りの砦)。
    /// 変異: 記録の照合を外して常に要約だけを出す → 記録なし・不一致の2件が落ちる / 常に `unbuilt:` を付ける → 一致の1件が落ちる
    func testProbeFlagsAnUnbuiltCloneUnlessTheBuildRecordMatchesTheHeadDigest() throws {
        let local = try AlignSnapshot.localTree(repoRoot: repo, includeTestProjects: true)
        let none = try XCTUnwrap(try probe())
        XCTAssertFalse(none.built, "no build record")
        XCTAssertEqual(none.digest, local.digest, "the digest is still reported (not used for matching when unbuilt)")
        try recordBuild(at: repo, digest: "0000000000000000000000000000000000000000")
        XCTAssertFalse(try XCTUnwrap(try probe()).built, "a record for another digest")
        try recordBuild(at: repo, digest: local.digest)
        let built = try XCTUnwrap(try probe())
        XCTAssertTrue(built.built)
        XCTAssertEqual(built.digest, local.digest)
    }

    func testParseRemoteProbeReadsTheUnbuiltPrefix() {
        let state = AlignSnapshot.parseRemoteProbe(["h", "unbuilt:abc", "h", "-"])
        XCTAssertEqual(state, AlignSnapshot.RemoteToolState(head: "h", digest: "abc", base: "h", snapshotIssuer: nil, built: false))
    }

    /// 照合だけの経路(TestProjects を `add -A` しない)と送る経路(含める)で要約が同じ。
    /// 変異: 除外の pathspec を外す → 下の「除外だけ」の assert は通るが、TestProjects の変更で isClean が割れる側が落ちる /
    /// 除外のとき `:(exclude)` の対象を変える(Sources を除く)→ 要約が割れて落ちる
    func testDigestIsTheSameWithAndWithoutTestProjectsInTheAdd() throws {
        try write("TestProjects/P/scenarios/s.swift", "let s = 2\n")
        try write("TestProjects/P/scenarios/new.swift", "let n = 1\n")
        let full = try AlignSnapshot.localTree(repoRoot: repo, includeTestProjects: true)
        let checkOnly = try AlignSnapshot.localTree(repoRoot: repo, includeTestProjects: false)
        XCTAssertEqual(checkOnly.digest, full.digest)
        XCTAssertFalse(full.isClean)
        XCTAssertTrue(checkOnly.isClean, "TestProjects-only changes are not part of the digest")
        XCTAssertNotEqual(checkOnly.tree, full.tree, "the check-only tree must not have staged TestProjects")
        try write("Sources/a.swift", "let a = 9\n")
        let both = try AlignSnapshot.localTree(repoRoot: repo, includeTestProjects: false)
        XCTAssertEqual(both.digest, try AlignSnapshot.localTree(repoRoot: repo, includeTestProjects: true).digest)
        XCTAssertFalse(both.isClean)
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

    /// ランナーの成功したビルドの記録(1行目 = 要約)を置く。パスは本番と同じ定数
    private func recordBuild(at clone: URL, digest: String) throws {
        let record = clone.appendingPathComponent(AlignSnapshot.builtRecordRelativePath)
        try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (digest + "\n").write(to: record, atomically: true, encoding: .utf8)
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
