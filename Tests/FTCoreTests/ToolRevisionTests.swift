// `--tool-rev`: 照合の手元の値(要約・向きの基点)を <rev> のコミットのツリーから求めること
// (`RemoteCompat.localTool` = checkCompatibility / remote status / api remote-compat が通る1箇所。
// `remote align --tool-rev` が送る要約もここ)。作業ツリーが汚れていても <rev> の値になる。一時リポジトリだけを触る。

import Foundation
import XCTest
import FTCore
import FTRemote

final class ToolRevisionTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("tool-rev-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try write("Sources/a.swift", "let a = 1\n")
        try git(["init", "-q"])
        try git(["add", "-A"])
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "base"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    func testToolRevHeadKeepsTheHeadDigestWhileTheWorkingTreeIsDirty() throws {
        let clean = try RemoteCompat.localTool(repoRoot: repo, toolRev: nil)
        try write("Sources/a.swift", "let a = 2\n")
        try write("Sources/untracked.swift", "let u = 1\n")
        let dirtyWorkingTree = try RemoteCompat.localTool(repoRoot: repo, toolRev: nil)
        XCTAssertNotEqual(dirtyWorkingTree.digest, clean.digest)
        XCTAssertFalse(dirtyWorkingTree.isClean)

        let atHead = try RemoteCompat.localTool(repoRoot: repo, toolRev: "HEAD")
        XCTAssertEqual(atHead.digest, clean.digest)
        XCTAssertEqual(atHead.head, clean.head)
        XCTAssertTrue(atHead.isClean)
    }

    func testToolRevOlderCommitUsesThatCommitAsTheBaseAndItsOwnDigest() throws {
        let first = try RemoteCompat.localTool(repoRoot: repo, toolRev: nil)
        try write("Sources/a.swift", "let a = 2\n")
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-a", "-m", "second"])
        let second = try RemoteCompat.localTool(repoRoot: repo, toolRev: nil)
        XCTAssertNotEqual(second.head, first.head)

        let older = try RemoteCompat.localTool(repoRoot: repo, toolRev: "HEAD~1")
        XCTAssertEqual(older.head, first.head, "the direction base must be the --tool-rev commit, not HEAD")
        XCTAssertEqual(older.digest, first.digest)
        XCTAssertNotEqual(older.digest, second.digest)
    }

    func testToolRevDigestEqualsWhatTheRunnerProbeReadsAfterTheCommitIsSentAsIs() throws {
        try write("Sources/a.swift", "let a = 2\n")
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-a", "-m", "second"])
        let head = try git(["rev-parse", "HEAD"])
        try write("Sources/a.swift", "let a = 3\n")   // 作業ツリーは HEAD と違う(送られない)
        let revision = try AlignSnapshot.revisionTree(repoRoot: repo, rev: "HEAD")
        XCTAssertEqual(revision.commit, head)

        let runner = repo.appendingPathComponent("runner-clone")
        try git(["clone", "-q", repo.path, runner.path])
        try git(["push", "-q", "--force", runner.path, "\(revision.commit):\(AlignSnapshot.pushRef)"])
        try git(["-C", runner.path, "checkout", "-q", "--detach", revision.commit])
        let result = try Shell.runData(["/bin/sh", "-c",
            AlignSnapshot.remoteProbeCommand(quotedToolRoot: "\"\(runner.path)\"")])
        let lines = String(decoding: result.data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        let state = try XCTUnwrap(AlignSnapshot.parseRemoteProbe(lines))
        XCTAssertEqual(state.digest, revision.digest)
        XCTAssertEqual(state.base, revision.commit)
        XCTAssertNil(state.snapshotIssuer)
    }

    func testToolRevThatIsNotACommitOrLooksLikeAnOptionIsRefused() {
        for bad in ["no-such-branch", "", "   ", "--help", "-x"] {
            XCTAssertThrowsError(try RemoteCompat.localTool(repoRoot: repo, toolRev: bad), "\(bad.debugDescription)")
        }
    }

    // MARK: - helpers

    private func write(_ relative: String, _ content: String) throws {
        try content.write(to: repo.appendingPathComponent(relative), atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func git(_ args: [String]) throws -> String {
        let result = try Shell.run(["git", "-C", repo.path] + args)
        XCTAssertEqual(result.status, 0, "git \(args): \(result.output)")
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
