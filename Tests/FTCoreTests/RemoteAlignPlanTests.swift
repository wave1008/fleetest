// RemoteAlignPlan(align の直送・「同じなら何もしない」の判定・ビルドの記録・全製品のビルドと省略)の純粋ロジック。
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

    private func probeOutput(head: String = "h1", toolDigest: String = "d1d1d1", record: [String] = ["d1d1d1", "-", "Xcode 27.2 Build version 1", "h1"],
                             binary: String = "yes", xcode: String = "Xcode 27.2 Build version 1") -> String {
        ([head, toolDigest, "h0", "-"] + record + [binary, xcode]).joined(separator: "\n") + "\n"
    }

    private func aligned(_ output: String, digest: String = "d1d1d1", developerDir: String? = nil) -> Bool {
        guard let state = RemoteAlignPlan.parseProbe(output) else { return false }
        return RemoteAlignPlan.isAlreadyAligned(commit: "h1", localDigest: digest, developerDir: developerDir, state: state)
    }

    func testParseProbeReadsEveryLine() throws {
        let state = try XCTUnwrap(RemoteAlignPlan.parseProbe(probeOutput(
            record: ["d1d1d1", "/Applications/X.app/Contents/Developer", "Xcode 27.2", "h1"])))
        XCTAssertEqual(state.tool?.digest, "d1d1d1")
        XCTAssertEqual(state.record, RemoteAlignPlan.BuildRecord(
            digest: "d1d1d1", developerDir: "/Applications/X.app/Contents/Developer", xcodeVersion: "Xcode 27.2", commit: "h1"))
        XCTAssertTrue(state.binaryExists)
    }

    func testParseProbeTreatsDashAsMissingAndShortOutputAsUnreadable() throws {
        let state = try XCTUnwrap(RemoteAlignPlan.parseProbe(probeOutput(
            record: ["-", "-", "-", "-"], binary: "no", xcode: "-")))
        XCTAssertNil(state.record)
        XCTAssertFalse(state.binaryExists)
        XCTAssertNil(RemoteAlignPlan.parseProbe("h1\nd1\n"))
    }

    func testAlreadyAlignedWhenEverythingMatches() {
        XCTAssertTrue(aligned(probeOutput()))
        XCTAssertTrue(aligned(probeOutput(record: ["d1d1d1", "/X/Developer", "Xcode 27.2 Build version 1", "h1"]),
                              developerDir: "/X/Developer"))
    }

    func testNotAlignedWhenTheRunnerContentsDiffer() { XCTAssertFalse(aligned(probeOutput(toolDigest: "other"))) }
    func testNotAlignedWhenTheRunnerContentsAreUnreadable() { XCTAssertFalse(aligned(probeOutput(head: "-", toolDigest: "-"))) }
    func testNotAlignedWhenThereIsNoBuildRecord() {
        XCTAssertFalse(aligned(probeOutput(record: ["-", "-", "-", "-"])))
    }
    func testNotAlignedWhenTheRecordDigestDiffers() {
        XCTAssertFalse(aligned(probeOutput(record: ["other", "-", "Xcode 27.2 Build version 1", "h1"])))
    }
    func testNotAlignedWhenTheDeveloperDirDiffers() {
        XCTAssertFalse(aligned(probeOutput(), developerDir: "/X/Developer"))
        XCTAssertFalse(aligned(probeOutput(record: ["d1d1d1", "/Y/Developer", "Xcode 27.2 Build version 1", "h1"]),
                               developerDir: "/X/Developer"))
    }
    func testNotAlignedWhenTheXcodeVersionDiffers() {
        XCTAssertFalse(aligned(probeOutput(xcode: "Xcode 27.3 Build version 2")))
    }
    /// 狙い: 要約だけで比べる形へ戻す変異で落ちる(要約は TestProjects を除くので、シナリオだけの変更は要約が同じ =
    /// HEAD とビルドの記録のコミットで見分ける。見分けないと `e2ex.sh --on` が古いシナリオを回す)
    func testNotAlignedWhenOnlyTheCommitDiffers() {
        XCTAssertFalse(aligned(probeOutput(head: "h2")))
        XCTAssertFalse(aligned(probeOutput(record: ["d1d1d1", "-", "Xcode 27.2 Build version 1", "h0"])))
    }
    func testNotAlignedWhenTheBinaryIsMissing() { XCTAssertFalse(aligned(probeOutput(binary: "no"))) }
    func testNotAlignedWhenTheLocalDigestDiffers() { XCTAssertFalse(aligned(probeOutput(), digest: "newer")) }

    func testProbeCommandIsValidShellAndAsksForTenLines() throws {
        for developerDir in [nil, "/Applications/Xcode 27.app/Contents/Developer"] {
            let command = RemoteAlignPlan.probeCommand(layout: layout, developerDir: developerDir)
            let syntax = try Shell.run(["/bin/sh", "-n", "-c", command])
            XCTAssertEqual(syntax.status, 0, syntax.output)
            XCTAssertEqual(command.hasPrefix("export DEVELOPER_DIR="), developerDir != nil)
        }
    }

    /// 実走: 何も無いディレクトリでも常に10行(読めない値は `-`)を返し、`parseProbe` が読める
    func testProbeCommandAlwaysPrintsTenLinesOnAnEmptyMachine() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = RemoteLayout(base: root.appendingPathComponent("runner").path, issuer: "alice", home: root.path)
        // ランナーのログインシェルは zsh(`echo -` が空行になる)。sh と zsh で同じ10行・空行なしを要る
        for shell in ["/bin/sh", "/bin/zsh"] {
            let result = try Shell.runData([shell, "-c", RemoteAlignPlan.probeCommand(layout: empty, developerDir: nil)])
            let text = String(data: result.data, encoding: .utf8) ?? ""
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
            XCTAssertEqual(lines.count, RemoteAlignPlan.probeLineCount, "\(shell): \(text)")
            XCTAssertFalse(lines.contains(where: \.isEmpty), "\(shell) printed an empty line: \(text)")
            let state = try XCTUnwrap(RemoteAlignPlan.parseProbe(text))
            XCTAssertNil(state.tool)
            XCTAssertNil(state.record)
            XCTAssertFalse(state.binaryExists)
        }
    }

    /// 狙い: `parseProbe` を先頭から読む形へ戻す変異で落ちる(ランナーのシェル初期化ファイルが先頭へ出す行に位置をずらされる)
    func testParseProbeReadsTheTrailingLinesWhenTheShellPrintsJunkFirst() throws {
        let clean = try XCTUnwrap(RemoteAlignPlan.parseProbe(probeOutput()))
        let noisy = "Last login: Tue Nov  4 09:00:00\nwelcome to the runner\n" + probeOutput()
        XCTAssertEqual(RemoteAlignPlan.parseProbe(noisy), clean)
        XCTAssertNil(RemoteAlignPlan.parseProbe("h1\nd1d1d1\n"), "too few lines is unreadable")
    }

    /// 狙い: `isAlreadyAligned` の `tool.built` を外す変異で落ちる(クローンの要約が一致していても未ビルドなら揃っていない)
    func testNotAlignedWhenTheCloneIsUnbuilt() {
        XCTAssertFalse(aligned(probeOutput(toolDigest: "unbuilt:d1d1d1")))
        XCTAssertTrue(aligned(probeOutput()))
    }

    // MARK: - `run --align` の安全弁

    private func state(digest: String? = "remote", built: Bool = true) -> RemoteAlignPlan.ProbeState {
        RemoteAlignPlan.ProbeState(
            tool: AlignSnapshot.RemoteToolState(head: "h", digest: digest, base: "b", snapshotIssuer: nil, built: built),
            record: nil, binaryExists: true, xcodeVersion: "x")
    }

    /// 狙い: `alignDecision` の `probe == nil` を `.proceed` へ倒す変異(照会が読めないのに送る)で落ちる
    func testAlignDecisionRefusesWhenTheProbeIsUnreadableOnlyIfGuarded() {
        func decide(guarded: Bool, probe: RemoteAlignPlan.ProbeState?) -> RemoteAlignPlan.RunAlignDecision {
            RemoteAlignPlan.alignDecision(guarded: guarded, localDigest: "local", probe: probe, relation: { _ in .localBehind })
        }
        XCTAssertEqual(decide(guarded: true, probe: nil), .refuseUnreadable)
        XCTAssertEqual(decide(guarded: false, probe: nil), .proceed)
        // 照会は読めたがクローンが無い(tool が nil)なら揃える
        XCTAssertEqual(decide(guarded: true, probe: RemoteAlignPlan.ProbeState(tool: nil, record: nil, binaryExists: false,
                                                                                  xcodeVersion: "-")), .proceed)
        XCTAssertEqual(decide(guarded: true, probe: state()), .refuse(.localBehind))
        XCTAssertEqual(decide(guarded: false, probe: state()), .proceed)
        XCTAssertEqual(decide(guarded: true, probe: state(digest: "local")), .proceed)
    }

    /// 狙い: `isGuarded` が `toolRev` を見ない変異で落ちる(`--tool-rev HEAD~1` が localBehind で止まる)
    func testToolRevDisablesTheGuard() {
        XCTAssertTrue(RemoteAlignPlan.isGuarded(requested: true, toolRev: nil))
        XCTAssertFalse(RemoteAlignPlan.isGuarded(requested: true, toolRev: "HEAD~1"))
        XCTAssertFalse(RemoteAlignPlan.isGuarded(requested: false, toolRev: nil))
    }

    // MARK: - ビルドのスクリプト(文字列)

    func testBuildScriptBuildsEveryProductInsideTheScriptAndWritesTheRecordLast() throws {
        let script = RemoteAlignPlan.buildScript(layout: layout, revision: "9655a21", digest: "d1", developerDir: nil)
        XCTAssertFalse(script.contains("git fetch"))
        XCTAssertTrue(script.contains("git checkout -q --detach \"$ft_rev\""))
        XCTAssertTrue(script.contains("ft_rev='9655a21'"))
        XCTAssertTrue(script.contains(" && swift build --product fleetest && "), script)
        for product in RemoteAlignPlan.buildOrder {
            XCTAssertTrue(script.contains("ft_build '\(product)' 'Sources/"), product)
        }
        XCTAssertFalse(script.contains("nohup"), "nothing is built in the background")
        // 記録は全部のビルドの後(末尾)に書く。古い記録はビルドの前に消す
        let rm = try XCTUnwrap(script.range(of: "rm -f \"$ft_rec\""))
        let build = try XCTUnwrap(script.range(of: "swift build --product fleetest &&"))
        let write = try XCTUnwrap(script.range(of: "> \"$ft_rec\""))
        XCTAssertLessThan(rm.lowerBound, build.lowerBound)
        XCTAssertLessThan(build.lowerBound, write.lowerBound)
        XCTAssertTrue(script.hasSuffix("> \"$ft_rec\""))
    }

    /// 狙い: `buildOrder` から製品を外す・閉包の表から製品を外す変異で落ちる(全製品が表にあり、表の製品が全部ビルド順にある)
    func testBuildOrderAndClosureTableCoverTheSameProducts() {
        XCTAssertEqual(Set(RemoteAlignPlan.buildOrder), Set(RemoteAlignPlan.productSourceClosure.keys))
        XCTAssertEqual(RemoteAlignPlan.buildOrder.count, Set(RemoteAlignPlan.buildOrder).count)
        XCTAssertFalse(RemoteAlignPlan.productSourceClosure.keys.contains("fleetest"), "fleetest is always built")
    }

    func testBuildScriptSkipConditionNamesEveryRequirement() {
        let script = RemoteAlignPlan.buildScript(layout: layout, revision: "9655a21", digest: "d1", developerDir: nil)
        for requirement in ["[ -n \"$ft_prev_rev\" ]", "[ \"$ft_prev_dev\" = \"$ft_dev\" ]", "[ \"$ft_prev_xc\" = \"$ft_xc\" ]",
                            "[ -x \"$ft_root/.build/debug/$ft_p\" ]",
                            "git diff --quiet \"$ft_prev_rev\" \"$ft_rev\" -- \"$@\" Package.swift Package.resolved"] {
            XCTAssertTrue(script.contains(requirement), requirement)
        }
        XCTAssertTrue(script.contains("skipping $ft_p"))
    }

    func testShellStringsAreValidSyntax() throws {
        for developerDir in [nil, "/Applications/Xcode 27.app/Contents/Developer"] {
            let script = RemoteAlignPlan.buildScript(layout: layout, revision: "9655a21", digest: "d1", developerDir: developerDir)
            let syntax = try Shell.run(["/bin/sh", "-n", "-c", script])
            XCTAssertEqual(syntax.status, 0, syntax.output + "\n" + script)
        }
    }

    // MARK: - 閉包の表と Package.swift の突き合わせ

    /// 表に漏れがあると、変わった依存を見ずに古いバイナリを残す(黙って誤る)ので、`swift package dump-package` の依存を
    /// 推移的にたどった閉包と等号で突き合わせる。外部パッケージの product は除く。`path:` を明示したターゲットはそれに従う。
    /// 狙い: 表から依存ディレクトリを1つ消す・余計な依存を足す変異で落ちる
    func testProductSourceClosureMatchesPackageManifest() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        // **scratch-path を一時ディレクトリにする** —— 既定の `.build` は走っている `swift test` が SwiftPM のロックを
        // 握っているので、同じ置き場で撃つとロックを待ち続けて止まる(実際に止まった)。期限は詰まったときに落とすため
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("dump-package-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let dump = try Shell.runData(["swift", "package", "--package-path", root.path, "--scratch-path", scratch.path,
                                      "dump-package"], timeout: 120)
        XCTAssertEqual(dump.status, 0, String(decoding: dump.data, as: UTF8.self).suffix(400).description)
        // 先頭に警告行が付いても読めるよう最初の `{` から読む
        let json = try XCTUnwrap(dump.data.firstIndex(of: UInt8(ascii: "{")).map { dump.data.subdata(in: $0..<dump.data.count) })
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let targets = try XCTUnwrap(manifest["targets"] as? [[String: Any]])
        var byName: [String: [String: Any]] = [:]
        for target in targets { if let name = target["name"] as? String { byName[name] = target } }

        func directory(_ name: String) -> String { (byName[name]?["path"] as? String) ?? "Sources/\(name)" }
        func dependencies(_ name: String) -> [String] {
            ((byName[name]?["dependencies"] as? [[String: Any]]) ?? []).flatMap { dependency -> [String] in
                for key in ["byName", "target"] {
                    if let values = dependency[key] as? [Any], let first = values.first as? String, byName[first] != nil {
                        return [first]
                    }
                }
                return []   // 外部パッケージの product
            }
        }
        func closure(of product: String) -> Set<String> {
            var seen: Set<String> = [], queue = [product]
            while let next = queue.popLast() {
                guard seen.insert(next).inserted else { continue }
                queue += dependencies(next)
            }
            return Set(seen.map(directory))
        }
        for (product, directories) in RemoteAlignPlan.productSourceClosure {
            XCTAssertNotNil(byName[product], "\(product) must be an executable target")
            XCTAssertEqual(Set(directories), closure(of: product), "closure of \(product)")
            XCTAssertEqual(directories.count, Set(directories).count, "no duplicates in \(product)")
        }
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

    /// 全製品(`fleetest` 以外は閉包が無変更なら省く)の実走。順序も固定
    func testBuildScriptRunsWritesTheRecordAndSkipsProductsWhoseClosureIsUnchanged() throws {
        let fixture = try Fixture()
        try fixture.git(["init", "--quiet"])
        try fixture.write("Package.swift", "// p\n")
        for directory in Set(RemoteAlignPlan.productSourceClosure.values.flatMap { $0 }) {
            try fixture.write("\(directory)/a.txt", "1")
        }
        let first = try fixture.commit("first")
        let all = ["fleetest"] + RemoteAlignPlan.buildOrder
        let helpers = [StreamHelpers.simstream, StreamHelpers.androidstream]

        // 記録が無い = 全部ビルド(順序も固定)
        var run = try fixture.run(revision: first, developerDir: nil)
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(run.products, all)
        let record = try XCTUnwrap(fixture.record)
        XCTAssertEqual(record.count, 4)
        XCTAssertEqual([record[0], record[1], record[3]], ["dg-\(first.prefix(4))", "-", first])

        // 記録があっても実行ファイルが無ければビルド
        run = try fixture.run(revision: first, developerDir: nil)
        XCTAssertEqual(run.products, all)

        // 実行ファイルがあり・無変更 = `fleetest` 以外を全部省く
        for product in RemoteAlignPlan.buildOrder { try fixture.makeExecutable(".build/debug/\(product)") }
        run = try fixture.run(revision: first, developerDir: nil)
        XCTAssertEqual(run.products, ["fleetest"])

        // developerDir が違えば全部ビルド
        run = try fixture.run(revision: first, developerDir: "/X/Developer")
        XCTAssertEqual(run.products, all)
        XCTAssertEqual(try XCTUnwrap(fixture.record)[1], "/X/Developer")

        // 片方の Sources だけ変えれば、その製品だけビルド
        try fixture.write("Sources/fleetest-androidstream/a.txt", "2")
        let second = try fixture.commit("second")
        run = try fixture.run(revision: second, developerDir: "/X/Developer")
        XCTAssertEqual(run.products, ["fleetest", StreamHelpers.androidstream])

        // 共有の依存(FTCore)が変われば、それを閉包に持つ製品だけビルド(配信ヘルパーは省く)
        try fixture.write("Sources/FTCore/a.txt", "2")
        let core = try fixture.commit("core")
        run = try fixture.run(revision: core, developerDir: "/X/Developer")
        XCTAssertEqual(run.products, ["fleetest"] + RemoteAlignPlan.buildOrder.filter { !helpers.contains($0) })

        // Package.swift が変われば全部ビルド
        try fixture.write("Package.swift", "// p2\n")
        let third = try fixture.commit("third")
        run = try fixture.run(revision: third, developerDir: "/X/Developer")
        XCTAssertEqual(run.products, all)
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
