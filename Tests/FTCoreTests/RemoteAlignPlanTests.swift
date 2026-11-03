// RemoteAlignPlan(align の直送・「同じなら何もしない」の判定・ビルドの記録・後回しのビルド)の純粋ロジック。
// 組み立てたシェル文字列は `/bin/sh -n` で構文を確かめ、ビルドの記録と省略は偽の `swift` を PATH に置いた実走で確かめる
// (本物のビルドは走らない)。

import Foundation
import XCTest
@testable import FTCore
import FTRemote

final class RemoteAlignPlanTests: XCTestCase {
    private let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice", home: "/Users/ci")

    // MARK: - push

    func testPushArgumentsGoDirectlyToTheToolRootWithoutOrigin() {
        let argv = RemoteAlignPlan.pushArguments(repoRoot: "/work/fleetest-mobile", sshTarget: "ci@mac2",
                                                 toolRoot: layout.toolRoot, commit: "abc1234")
        XCTAssertEqual(Array(argv.dropFirst()), ["git", "-C", "/work/fleetest-mobile", "push", "--force", "--no-verify",
                                                 "ci@mac2:/Users/ci/fleetest-runner/fleetest-mobile",
                                                 "abc1234:refs/fleetest/align"])
        XCTAssertFalse(argv.contains("origin"))
    }

    /// ssh の引数は SSHOptions を通す(接続の上限とキープアライブ)。1語ずつ引用されて git のシェルへ渡る
    func testPushSshCommandFoldsInSSHOptions() {
        let env = RemoteAlignPlan.pushArguments(repoRoot: "/r", sshTarget: "h", toolRoot: "/t", commit: "c")[0]
        XCTAssertEqual(env, "GIT_SSH_COMMAND='ssh' '-o' 'BatchMode=yes' '-o' 'ConnectTimeout=10' "
            + "'-o' 'ServerAliveInterval=15' '-o' 'ServerAliveCountMax=4'")
    }

    func testSendLine() {
        XCTAssertEqual(RemoteAlignPlan.sendLine(commit: "abcdef0123", isSnapshot: false, untrackedCount: 0, untrackedBytes: 0),
                       "sending HEAD abcdef0 (untracked files included: 0, 0.0 MB)")
        XCTAssertEqual(RemoteAlignPlan.sendLine(commit: "abcdef0123", isSnapshot: true, untrackedCount: 3,
                                                untrackedBytes: 1_572_864),
                       "sending working tree snapshot abcdef0 (untracked files included: 3, 1.5 MB)")
    }

    // MARK: - 照会の読み取りと判定

    private let digest = "d1d1d1"

    private func probeOutput(head: String = "h1", toolDigest: String = "d1d1d1", record: [String] = ["d1d1d1", "-", "Xcode 27.2 Build version 1", "c1"],
                             deferred: String = "d1d1d1 0", binary: String = "yes", xcode: String = "Xcode 27.2 Build version 1") -> String {
        ([head, toolDigest, "h0", "-"] + record + [deferred, binary, xcode]).joined(separator: "\n") + "\n"
    }

    private func aligned(_ output: String, digest: String = "d1d1d1", developerDir: String? = nil) -> Bool {
        guard let state = RemoteAlignPlan.parseProbe(output) else { return false }
        return RemoteAlignPlan.isAlreadyAligned(localDigest: digest, developerDir: developerDir, state: state)
    }

    func testParseProbeReadsEveryLine() throws {
        let state = try XCTUnwrap(RemoteAlignPlan.parseProbe(probeOutput(
            record: ["d1d1d1", "/Applications/X.app/Contents/Developer", "Xcode 27.2", "c1"], deferred: "d1d1d1 3")))
        XCTAssertEqual(state.tool?.digest, "d1d1d1")
        XCTAssertEqual(state.record, RemoteAlignPlan.BuildRecord(
            digest: "d1d1d1", developerDir: "/Applications/X.app/Contents/Developer", xcodeVersion: "Xcode 27.2", commit: "c1"))
        XCTAssertEqual(state.deferred, RemoteAlignPlan.DeferredRecord(digest: "d1d1d1", exitCode: 3))
        XCTAssertTrue(state.binaryExists)
    }

    func testParseProbeTreatsDashAsMissingAndShortOutputAsUnreadable() throws {
        let state = try XCTUnwrap(RemoteAlignPlan.parseProbe(probeOutput(
            record: ["-", "-", "-", "-"], deferred: "-", binary: "no", xcode: "-")))
        XCTAssertNil(state.record)
        XCTAssertNil(state.deferred)
        XCTAssertFalse(state.binaryExists)
        XCTAssertNil(RemoteAlignPlan.parseProbe("h1\nd1\n"))
    }

    func testAlreadyAlignedWhenEverythingMatches() {
        XCTAssertTrue(aligned(probeOutput()))
        XCTAssertTrue(aligned(probeOutput(record: ["d1d1d1", "/X/Developer", "Xcode 27.2 Build version 1", "c1"]),
                              developerDir: "/X/Developer"))
    }

    func testNotAlignedWhenTheRunnerContentsDiffer() { XCTAssertFalse(aligned(probeOutput(toolDigest: "other"))) }
    func testNotAlignedWhenTheRunnerContentsAreUnreadable() { XCTAssertFalse(aligned(probeOutput(head: "-", toolDigest: "-"))) }
    func testNotAlignedWhenThereIsNoBuildRecord() {
        XCTAssertFalse(aligned(probeOutput(record: ["-", "-", "-", "-"])))
    }
    func testNotAlignedWhenTheRecordDigestDiffers() {
        XCTAssertFalse(aligned(probeOutput(record: ["other", "-", "Xcode 27.2 Build version 1", "c1"])))
    }
    func testNotAlignedWhenTheDeveloperDirDiffers() {
        XCTAssertFalse(aligned(probeOutput(), developerDir: "/X/Developer"))
        XCTAssertFalse(aligned(probeOutput(record: ["d1d1d1", "/Y/Developer", "Xcode 27.2 Build version 1", "c1"]),
                               developerDir: "/X/Developer"))
    }
    func testNotAlignedWhenTheXcodeVersionDiffers() {
        XCTAssertFalse(aligned(probeOutput(xcode: "Xcode 27.3 Build version 2")))
    }
    func testNotAlignedWhenTheDeferredBuildIsMissing() { XCTAssertFalse(aligned(probeOutput(deferred: "-"))) }
    func testNotAlignedWhenTheDeferredBuildHasAnotherDigest() { XCTAssertFalse(aligned(probeOutput(deferred: "other 0"))) }
    func testNotAlignedWhenTheDeferredBuildFailed() { XCTAssertFalse(aligned(probeOutput(deferred: "d1d1d1 2"))) }
    func testNotAlignedWhenTheBinaryIsMissing() { XCTAssertFalse(aligned(probeOutput(binary: "no"))) }
    func testNotAlignedWhenTheLocalDigestDiffers() { XCTAssertFalse(aligned(probeOutput(), digest: "newer")) }

    func testProbeCommandIsValidShellAndAsksForElevenLines() throws {
        for developerDir in [nil, "/Applications/Xcode 27.app/Contents/Developer"] {
            let command = RemoteAlignPlan.probeCommand(layout: layout, developerDir: developerDir)
            let syntax = try Shell.run(["/bin/sh", "-n", "-c", command])
            XCTAssertEqual(syntax.status, 0, syntax.output)
            XCTAssertEqual(command.hasPrefix("export DEVELOPER_DIR="), developerDir != nil)
        }
    }

    /// 実走: 何も無いディレクトリでも常に11行(読めない値は `-`)を返し、`parseProbe` が読める
    func testProbeCommandAlwaysPrintsElevenLinesOnAnEmptyMachine() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = RemoteLayout(base: root.appendingPathComponent("runner").path, issuer: "alice", home: root.path)
        let result = try Shell.runData(["/bin/sh", "-c", RemoteAlignPlan.probeCommand(layout: empty, developerDir: nil)])
        let text = String(data: result.data, encoding: .utf8) ?? ""
        XCTAssertEqual(text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().count, 11, text)
        let state = try XCTUnwrap(RemoteAlignPlan.parseProbe(text))
        XCTAssertNil(state.tool)
        XCTAssertNil(state.record)
        XCTAssertNil(state.deferred)
        XCTAssertFalse(state.binaryExists)
    }

    // MARK: - ビルドのスクリプト(文字列)

    func testBuildScriptAlwaysBuildsFleetestAndServicesAndDefersTheRest() throws {
        let script = RemoteAlignPlan.buildScript(layout: layout, revision: "9655a21", digest: "d1", developerDir: nil)
        XCTAssertFalse(script.contains("git fetch"))
        XCTAssertTrue(script.contains("git checkout --detach \"$ft_rev\""))
        XCTAssertTrue(script.contains("ft_rev='9655a21'"))
        XCTAssertTrue(script.contains(" && swift build --product fleetest && "), script)
        XCTAssertTrue(script.contains(" && swift build --product fleetest-services && "), script)
        XCTAssertTrue(script.contains("ft_build fleetest-simstream && ft_build fleetest-androidstream"), script)
        XCTAssertFalse(script.contains("fleetest-devicepoll"))
        XCTAssertFalse(script.contains("fleetest-mcp"))
        // 記録は全部のビルドの後(末尾)に書く。古い記録はビルドの前に消す
        let rm = try XCTUnwrap(script.range(of: "rm -f \"$ft_rec\""))
        let build = try XCTUnwrap(script.range(of: "swift build --product fleetest &&"))
        let write = try XCTUnwrap(script.range(of: "> \"$ft_rec\""))
        XCTAssertLessThan(rm.lowerBound, build.lowerBound)
        XCTAssertLessThan(build.lowerBound, write.lowerBound)
        XCTAssertTrue(script.hasSuffix("> \"$ft_rec\""))
    }

    func testBuildScriptSkipConditionNamesEveryRequirement() {
        let script = RemoteAlignPlan.buildScript(layout: layout, revision: "9655a21", digest: "d1", developerDir: nil)
        for requirement in ["[ -n \"$ft_prev_rev\" ]", "[ \"$ft_prev_dev\" = \"$ft_dev\" ]", "[ \"$ft_prev_xc\" = \"$ft_xc\" ]",
                            "[ -x \"$ft_root/.build/debug/$1\" ]",
                            "git diff --quiet \"$ft_prev_rev\" \"$ft_rev\" -- \"Sources/$1\" Package.swift Package.resolved"] {
            XCTAssertTrue(script.contains(requirement), requirement)
        }
        XCTAssertTrue(script.contains("skipping $1"))
    }

    func testShellStringsAreValidSyntax() throws {
        for developerDir in [nil, "/Applications/Xcode 27.app/Contents/Developer"] {
            for script in [RemoteAlignPlan.buildScript(layout: layout, revision: "9655a21", digest: "d1", developerDir: developerDir),
                           RemoteAlignPlan.deferredBuildCommand(layout: layout, digest: "d1", developerDir: developerDir)] {
                let syntax = try Shell.run(["/bin/sh", "-n", "-c", script])
                XCTAssertEqual(syntax.status, 0, syntax.output + "\n" + script)
            }
        }
    }

    // MARK: - 後回しのビルド

    func testDeferredBuildBuildsDevicepollAndMcpInOrderAndReturnsAtOnce() {
        let command = RemoteAlignPlan.deferredBuildCommand(layout: layout, digest: "d1",
                                                           developerDir: "/X/Developer")
        XCTAssertEqual(RemoteAlignPlan.deferredProducts, ["fleetest-devicepoll", "fleetest-mcp"])
        XCTAssertTrue(command.hasPrefix("export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"; "
            + "export DEVELOPER_DIR='/X/Developer'; "), command)
        XCTAssertTrue(command.contains("swift build --product fleetest-devicepoll && swift build --product fleetest-mcp; ft_exit=$?"))
        XCTAssertTrue(command.contains("> '/Users/ci/fleetest-runner/fleetest-mobile/.fleetest/align-deferred.log' 2>&1 < /dev/null & }"), command)
        // `&` は nohup だけを包む(列全体が裏へ回ると ssh が返らない)
        XCTAssertTrue(command.contains("&& { nohup sh -c "), command)
        XCTAssertFalse(RemoteAlignPlan.deferredBuildCommand(layout: layout, digest: "d1", developerDir: nil)
            .contains("DEVELOPER_DIR"))
    }

    // MARK: - 実走(偽の swift)

    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("align-" + UUID().uuidString)
        let layout: RemoteLayout
        let bin: URL
        let log: URL
        init() throws {
            layout = RemoteLayout(base: root.appendingPathComponent("runner").path, issuer: "alice", home: root.path)
            bin = root.appendingPathComponent("bin")
            log = root.appendingPathComponent("swift.log")
            try FileManager.default.createDirectory(atPath: layout.toolRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let fake = bin.appendingPathComponent("swift")
            try Data("#!/bin/sh\necho \"$@\" >> '\(log.path)'\n[ -z \"$FT_FAKE_FAIL\" ]\n".utf8).write(to: fake)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        @discardableResult func git(_ arguments: [String]) throws -> String {
            let result = try Shell.run(["/usr/bin/git", "-C", layout.toolRoot, "-c", "user.name=T", "-c", "user.email=t@e.invalid",
                                        "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments)
            XCTAssertEqual(result.status, 0, result.output)
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func write(_ relative: String, _ text: String) throws {
            let url = URL(fileURLWithPath: layout.toolRoot).appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func commit(_ message: String) throws -> String {
            try git(["add", "-A"])
            try git(["commit", "--quiet", "-m", message])
            return try git(["rev-parse", "HEAD"])
        }
        func makeExecutable(_ relative: String) throws {
            let url = URL(fileURLWithPath: layout.toolRoot).appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        /// 実行して、偽の swift が受けた製品名(順)を返す
        func run(revision: String, developerDir: String?, fail: Bool = false) throws -> (status: Int32, products: [String]) {
            try? FileManager.default.removeItem(at: log)
            let script = RemoteAlignPlan.buildScript(layout: layout, revision: revision, digest: "dg-\(revision.prefix(4))",
                                                     developerDir: developerDir)
            var argv = ["/usr/bin/env", "PATH=\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin"]
            if fail { argv.append("FT_FAKE_FAIL=1") }
            let result = try Shell.run(argv + ["/bin/sh", "-c", script])
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let products = text.split(separator: "\n").map { $0.replacingOccurrences(of: "build --product ", with: "") }
            return (result.status, products)
        }
        var record: [String]? {
            let url = URL(fileURLWithPath: RemoteAlignPlan.builtRecordPath(layout: layout))
            return (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n", omittingEmptySubsequences: false)
                .dropLast().map(String.init)
        }
    }

    func testBuildScriptRunsWritesTheRecordAndSkipsUnchangedStreamHelpers() throws {
        let fixture = try Fixture()
        try fixture.git(["init", "--quiet"])
        try fixture.write("Package.swift", "// p\n")
        try fixture.write("Sources/fleetest-simstream/a.txt", "1")
        try fixture.write("Sources/fleetest-androidstream/a.txt", "1")
        let first = try fixture.commit("first")

        // 記録が無い = 全部ビルド(順序も固定)
        var run = try fixture.run(revision: first, developerDir: nil)
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(run.products, ["fleetest", "fleetest-simstream", "fleetest-androidstream", "fleetest-services"])
        let record = try XCTUnwrap(fixture.record)
        XCTAssertEqual(record.count, 4)
        XCTAssertEqual([record[0], record[1], record[3]], ["dg-\(first.prefix(4))", "-", first])

        // 記録があっても実行ファイルが無ければビルド
        run = try fixture.run(revision: first, developerDir: nil)
        XCTAssertEqual(run.products, ["fleetest", "fleetest-simstream", "fleetest-androidstream", "fleetest-services"])

        // 実行ファイルがあり・無変更 = 配信ヘルパーを省く(fleetest と services は必ずビルド)
        try fixture.makeExecutable(".build/debug/fleetest-simstream")
        try fixture.makeExecutable(".build/debug/fleetest-androidstream")
        run = try fixture.run(revision: first, developerDir: nil)
        XCTAssertEqual(run.products, ["fleetest", "fleetest-services"])

        // developerDir が違えば両方ビルド
        run = try fixture.run(revision: first, developerDir: "/X/Developer")
        XCTAssertEqual(run.products, ["fleetest", "fleetest-simstream", "fleetest-androidstream", "fleetest-services"])
        XCTAssertEqual(try XCTUnwrap(fixture.record)[1], "/X/Developer")

        // 片方の Sources だけ変えれば、その製品だけビルド
        try fixture.write("Sources/fleetest-androidstream/a.txt", "2")
        let second = try fixture.commit("second")
        run = try fixture.run(revision: second, developerDir: "/X/Developer")
        XCTAssertEqual(run.products, ["fleetest", "fleetest-androidstream", "fleetest-services"])

        // Package.swift が変われば両方ビルド
        try fixture.write("Package.swift", "// p2\n")
        let third = try fixture.commit("third")
        run = try fixture.run(revision: third, developerDir: "/X/Developer")
        XCTAssertEqual(run.products, ["fleetest", "fleetest-simstream", "fleetest-androidstream", "fleetest-services"])
        XCTAssertEqual(try git(fixture, "rev-parse", "HEAD"), third)
    }

    func testFailedBuildLeavesNoRecord() throws {
        let fixture = try Fixture()
        try fixture.git(["init", "--quiet"])
        try fixture.write("Package.swift", "// p\n")
        let first = try fixture.commit("first")
        XCTAssertEqual(try fixture.run(revision: first, developerDir: nil).status, 0)
        XCTAssertNotNil(fixture.record)
        let failed = try fixture.run(revision: first, developerDir: nil, fail: true)
        XCTAssertNotEqual(failed.status, 0)
        XCTAssertNil(fixture.record, "失敗した回の古い記録を残さない")
    }

    private func git(_ fixture: Fixture, _ arguments: String...) throws -> String { try fixture.git(arguments) }
}
