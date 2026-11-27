import FTCore
import XCTest
@testable import FTRemote

/// `remote align` が手元のビルド済みの製品を送る仕組み(判定・鮮度・ランナー側の取り込み)
final class AlignPrebuiltTests: XCTestCase {
    private func conditions(workingTree: Bool = true, clone: Bool = true, fresh: Bool = true, readable: Bool = true,
                            runner: Bool? = true, unchanged: Bool = false) -> AlignPrebuilt.Conditions {
        .init(fromWorkingTree: workingTree, builtInThisClone: clone, binaryFresh: fresh, localToolchainReadable: readable,
              runnerToolchainIdentical: runner, unchangedSinceLastBuild: unchanged)
    }

    /// 狙い: 条件を1つ欠くと理由つきでランナーのビルドへ倒れる(どの条件も落とす変異で赤)・全部揃えば送る・ランナーが省くなら送らない
    func testDecisionTable() {
        XCTAssertEqual(AlignPrebuilt.decide(conditions()), .ship)
        XCTAssertEqual(AlignPrebuilt.decide(conditions(runner: nil)), .ship, "照会が無いときはランナー側の照合に任せて送る")
        func reason(_ c: AlignPrebuilt.Conditions) -> String? {
            if case .buildOnRunner(let reason) = AlignPrebuilt.decide(c) { return reason }
            return nil
        }
        XCTAssertTrue(try XCTUnwrap(reason(conditions(workingTree: false))).contains("--tool-rev"))
        XCTAssertTrue(try XCTUnwrap(reason(conditions(clone: false))).contains("this clone"))
        XCTAssertTrue(try XCTUnwrap(reason(conditions(fresh: false))).contains("older than its sources"))
        XCTAssertTrue(try XCTUnwrap(reason(conditions(readable: false))).contains("Xcode version could not be read"))
        XCTAssertTrue(try XCTUnwrap(reason(conditions(runner: false))).contains("Xcode differs"))
        XCTAssertEqual(AlignPrebuilt.decide(conditions(fresh: false, unchanged: true)), .notNeeded,
                       "ランナーが省く製品は鮮度に関わらず送らない(理由も言わない)")
    }

    func testPlanKeepsBuildOrderAndOmitsNotNeeded() {
        var decisions: [String: AlignPrebuilt.Decision] = ["fleetest": .ship]
        for product in RemoteAlignPlan.buildOrder { decisions[product] = .ship }
        decisions[RemoteAlignPlan.mcpProduct] = .buildOnRunner(reason: "r")
        decisions[StreamHelpers.simstream] = .notNeeded
        let plan = AlignPrebuilt.plan(decisions: decisions, localToolchain: "Xcode 1")
        XCTAssertEqual(plan.shipped, ["fleetest"] + RemoteAlignPlan.buildOrder.filter {
            $0 != RemoteAlignPlan.mcpProduct && $0 != StreamHelpers.simstream })
        XCTAssertEqual(plan.reasons, [RemoteAlignPlan.mcpProduct: "r"])
        XCTAssertFalse(plan.isActive)
        XCTAssertTrue(plan.staged(in: "/tmp/x").isActive)
    }

    // MARK: - 鮮度(実ファイル)

    private final class Tree {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("align-prebuilt-" + UUID().uuidString)
        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: root) }
        func write(_ relative: String, at date: Date, executable: Bool = false) throws -> URL {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: date, .posixPermissions: executable ? 0o755 : 0o644],
                                                  ofItemAtPath: url.path)
            return url
        }
        func touch(_ relative: String, _ date: Date) throws {
            try FileManager.default.setAttributes([.modificationDate: date],
                                                  ofItemAtPath: root.appendingPathComponent(relative).path)
        }
        /// simstream の入力を全部 `inputs` の時刻で置く(閉包は `Sources/fleetest-simstream` と Package.swift)
        func simstreamTree(inputs: Date) throws {
            for relative in AlignPrebuilt.inputPaths(product: StreamHelpers.simstream) where relative != "Package.resolved" {
                if relative == "Package.swift" { _ = try write(relative, at: inputs) } else {
                    _ = try write(relative + "/a.swift", at: inputs)
                    try touch(relative, inputs)
                }
            }
        }
    }

    /// 狙い: 比較を `<` から `<=` / 逆向きへ変える変異・入力の時刻を見ない変異・欠けた入力を無視する変異で落ちる
    func testFreshnessComparesBinaryWithEveryInput() throws {
        let tree = try Tree()
        let old = Date(timeIntervalSince1970: 1_000_000), mid = Date(timeIntervalSince1970: 2_000_000),
            new = Date(timeIntervalSince1970: 3_000_000)
        let product = StreamHelpers.simstream
        try tree.simstreamTree(inputs: old)
        let binary = try tree.write(".build/debug/\(product)", at: mid, executable: true)
        func fresh() -> Bool { AlignPrebuilt.isFresh(binary: binary, repoRoot: tree.root, product: product) }
        XCTAssertTrue(fresh(), "Package.resolved が無くてもよい")

        try tree.touch("Sources/fleetest-simstream/a.swift", new)
        XCTAssertFalse(fresh(), "ソースがバイナリより新しい")
        try tree.touch("Sources/fleetest-simstream/a.swift", mid)
        XCTAssertFalse(fresh(), "同時刻は新しいと言わない")
        try tree.touch("Sources/fleetest-simstream/a.swift", old)
        XCTAssertTrue(fresh())

        try tree.touch("Package.swift", new)
        XCTAssertFalse(fresh(), "Package.swift も入力")
        try tree.touch("Package.swift", old)
        _ = try tree.write("Package.resolved", at: new)
        XCTAssertFalse(fresh(), "Package.resolved も入力")
        try FileManager.default.removeItem(at: tree.root.appendingPathComponent("Package.resolved"))
        XCTAssertTrue(fresh())

        // 削除はディレクトリの時刻にしか出ない
        try tree.touch("Sources/fleetest-simstream", new)
        XCTAssertFalse(fresh(), "ディレクトリの更新(ファイルの削除)")
        try tree.touch("Sources/fleetest-simstream", old)

        try FileManager.default.removeItem(at: tree.root.appendingPathComponent("Sources/fleetest-simstream"))
        XCTAssertFalse(fresh(), "閉包のディレクトリが無ければ判定できない = 新しくない")
    }

    func testFreshnessRejectsMissingOrNonExecutableBinary() throws {
        let tree = try Tree()
        let old = Date(timeIntervalSince1970: 1_000_000), new = Date(timeIntervalSince1970: 3_000_000)
        let product = StreamHelpers.simstream
        try tree.simstreamTree(inputs: old)
        let missing = tree.root.appendingPathComponent(".build/debug/\(product)")
        XCTAssertFalse(AlignPrebuilt.isFresh(binary: missing, repoRoot: tree.root, product: product))
        let plain = try tree.write(".build/debug/plain", at: new, executable: false)
        XCTAssertFalse(AlignPrebuilt.isFresh(binary: plain, repoRoot: tree.root, product: product), "実行できないファイル")
    }

    /// 隠しファイル(.DS_Store・.build)は入力に数えない
    func testFreshnessIgnoresHiddenFiles() throws {
        let tree = try Tree()
        let old = Date(timeIntervalSince1970: 1_000_000), mid = Date(timeIntervalSince1970: 2_000_000),
            new = Date(timeIntervalSince1970: 3_000_000)
        let product = StreamHelpers.simstream
        try tree.simstreamTree(inputs: old)
        let binary = try tree.write(".build/debug/\(product)", at: mid, executable: true)
        _ = try tree.write("Sources/fleetest-simstream/.DS_Store", at: new)
        try tree.touch("Sources/fleetest-simstream", old)
        XCTAssertTrue(AlignPrebuilt.isFresh(binary: binary, repoRoot: tree.root, product: product))
    }

    /// 表は `Package.swift` の閉包と別に持つ `fleetest` の閉包を含め、全製品に入力がある
    func testEveryShippedProductHasInputs() {
        for product in ["fleetest"] + RemoteAlignPlan.buildOrder {
            XCTAssertTrue(AlignPrebuilt.inputPaths(product: product).contains("Package.swift"), product)
            XCTAssertGreaterThan(AlignPrebuilt.inputPaths(product: product).count, 2, "\(product) の閉包が空")
        }
    }

    func testLocalToolchainLineMatchesTheRunnerSideOneLine() {
        let fingerprint = ToolchainFingerprint.compose(xcodeVersionOutput: "Xcode 27.0\nBuild version 27A5228h\n", sdkBuild: "24A434")
        XCTAssertEqual(AlignPrebuilt.localToolchainLine(fingerprint: fingerprint), "Xcode 27.0 Build version 27A5228h")
        // ランナー側(`xcodeVersionOneLine`)と同じ式を実際にシェルで通した値と一致する
        let shell = (try? Shell.run(["/bin/sh", "-c", "printf 'Xcode 27.0\\nBuild version 27A5228h\\n' | tr '\\n' ' ' | sed 's/ *$//'"]))?.output
        XCTAssertEqual(shell, "Xcode 27.0 Build version 27A5228h")
        XCTAssertTrue(RemoteAlignPlan.xcodeVersionOneLine.hasSuffix("tr '\\n' ' ' | sed 's/ *$//'"))
        XCTAssertNil(AlignPrebuilt.localToolchainLine(fingerprint: nil))
        XCTAssertNil(AlignPrebuilt.localToolchainLine(fingerprint: "garbage"))
    }

    // MARK: - ランナー側(スクリプトを実際に走らせる)

    private final class Runner {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("align-install-" + UUID().uuidString)
        let layout: RemoteLayout
        let bin: URL, stage: URL, log: URL
        var toolRoot: URL { URL(fileURLWithPath: layout.toolRoot) }
        init(xcodeLine: String = "Xcode 99.0 Build version 99A1", machoStatus: Int32 = 0) throws {
            layout = RemoteLayout(base: root.appendingPathComponent("runner").path, issuer: "alice", home: root.path)
            bin = root.appendingPathComponent("bin")
            stage = root.appendingPathComponent("stage")
            log = root.appendingPathComponent("swift.log")
            for dir in [toolRoot, bin, stage] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            try script(bin.appendingPathComponent("swift"), "echo \"$@\" >> '\(log.path)'\n")
            let lines = xcodeLine.replacingOccurrences(of: " Build", with: "\\nBuild")
            try script(bin.appendingPathComponent("xcodebuild"), "printf '\(lines)\\n'\n")
            // ヘルパー(= 手元の fleetest)の代役: `api macho-check <file>` だけ答える
            try script(stage.appendingPathComponent("fleetest"),
                       "[ \"$1 $2\" = 'api macho-check' ] || exit 99\necho \"fake verdict for $3\"\nexit \(machoStatus)\n")
            try git(["init", "--quiet"])
            try Data("// p\n".utf8).write(to: toolRoot.appendingPathComponent("Package.swift"))
            try git(["add", "-A"])
            try git(["commit", "--quiet", "-m", "c"])
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func script(_ url: URL, _ body: String) throws {
            try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        @discardableResult func git(_ arguments: [String]) throws -> String {
            let result = try Shell.run(["/usr/bin/git", "-C", layout.toolRoot, "-c", "user.name=T", "-c", "user.email=t@e.invalid",
                                        "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments)
            XCTAssertEqual(result.status, 0, result.output)
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func stageProduct(_ name: String, _ content: String) throws {
            try script(stage.appendingPathComponent(name), "# \(content)\n")
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage.appendingPathComponent(name).path)
        }
        /// `.build/debug` → `.build/out/Products/Debug`(実体)
        func makeProductsDirectory() throws -> URL {
            let real = toolRoot.appendingPathComponent(".build/out/Products/Debug")
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: toolRoot.appendingPathComponent(".build/debug").path,
                                                       withDestinationPath: "out/Products/Debug")
            return real
        }
        func plan(shipped: [String], reasons: [String: String] = [:], toolchain: String = "Xcode 99.0 Build version 99A1")
            -> AlignPrebuilt.Plan {
            AlignPrebuilt.Plan(shipped: shipped, reasons: reasons, localToolchain: toolchain, stagingDirectory: stage.path)
        }
        func run(_ plan: AlignPrebuilt.Plan) throws -> (status: Int32, output: String, built: [String]) {
            try? FileManager.default.removeItem(at: log)
            let script = RemoteAlignPlan.buildScript(layout: layout, revision: try git(["rev-parse", "HEAD"]), digest: "d",
                                                     developerDir: nil, prebuilt: plan)
            let result = try Shell.run(["/usr/bin/env", "PATH=\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin", "/bin/sh", "-c", script])
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return (result.status, result.output,
                    text.split(separator: "\n").map { $0.replacingOccurrences(of: "build --product ", with: "") })
        }
    }

    private var allProducts: [String] { ["fleetest"] + RemoteAlignPlan.buildOrder }

    /// 狙い: 取り込みの分岐を外す変異(常にビルド)・送られた製品を取り込まずに記録だけ書く変異で落ちる
    func testInstallsShippedProductsAtomicallyAndBuildsTheRest() throws {
        let runner = try Runner()
        let products = try runner.makeProductsDirectory()
        let shipped = ["fleetest", RemoteAlignPlan.mcpProduct]
        try runner.stageProduct(RemoteAlignPlan.mcpProduct, "mcp")
        // 旧版が走っていても壊さない = 同じファイルへ書かず新しい名前から mv で差し替える
        try Data("old".utf8).write(to: products.appendingPathComponent("fleetest"))
        let oldInode = try XCTUnwrap(try FileManager.default.attributesOfItem(
            atPath: products.appendingPathComponent("fleetest").path)[.systemFileNumber] as? NSNumber)

        let result = try runner.run(runner.plan(shipped: shipped,
                                               reasons: [StreamHelpers.simstream: "local build is old"]))

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("installed the prebuilt fleetest sent from this Mac ("), result.output)
        XCTAssertTrue(result.output.contains("installed the prebuilt \(RemoteAlignPlan.mcpProduct) sent from this Mac ("), result.output)
        XCTAssertTrue(result.output.contains("building \(StreamHelpers.simstream) here (no prebuilt one was sent: local build is old)"),
                      result.output)
        XCTAssertEqual(result.built, RemoteAlignPlan.buildOrder.filter { $0 != RemoteAlignPlan.mcpProduct },
                       "取り込んだ製品は swift build しない")
        let installed = products.appendingPathComponent(RemoteAlignPlan.mcpProduct)
        XCTAssertEqual(try String(contentsOf: installed, encoding: .utf8), "#!/bin/sh\n# mcp\n")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.path), "実行ビットは付ける")
        XCTAssertNotEqual(try XCTUnwrap(try FileManager.default.attributesOfItem(
            atPath: products.appendingPathComponent("fleetest").path)[.systemFileNumber] as? NSNumber), oldInode,
                          "同じ inode へ書き込まない(走っている旧版を壊さない)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: products.path).filter { $0.hasPrefix(".") }, [],
                       "一時ファイルを残さない")
        XCTAssertNotNil(try? String(contentsOfFile: RemoteAlignPlan.builtRecordPath(layout: runner.layout), encoding: .utf8),
                        "全部そろった後に記録を書く")
    }

    /// 狙い: ランナー側の `api macho-check` の失敗を無視する変異(照合を外す)で落ちる。取り込まずビルドへ倒れ、理由を言う
    func testRunnerSideMachOCheckFailureFallsBackToBuild() throws {
        let runner = try Runner(machoStatus: 1)
        let products = try runner.makeProductsDirectory()
        try runner.stageProduct(RemoteAlignPlan.mcpProduct, "mcp")
        try Data("old".utf8).write(to: products.appendingPathComponent(RemoteAlignPlan.mcpProduct))

        let result = try runner.run(runner.plan(shipped: ["fleetest", RemoteAlignPlan.mcpProduct]))

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains(
            "building \(RemoteAlignPlan.mcpProduct) here: the prebuilt binary cannot run on this runner (fake verdict for"), result.output)
        XCTAssertEqual(result.built, allProducts, "全製品がランナーでビルドされる")
        XCTAssertEqual(try String(contentsOf: products.appendingPathComponent(RemoteAlignPlan.mcpProduct), encoding: .utf8), "old")
    }

    func testToolchainMismatchOnRunnerFallsBackToBuild() throws {
        let runner = try Runner(xcodeLine: "Xcode 99.0 Build version 99A1")
        _ = try runner.makeProductsDirectory()
        try runner.stageProduct(RemoteAlignPlan.mcpProduct, "mcp")
        let result = try runner.run(runner.plan(shipped: ["fleetest", RemoteAlignPlan.mcpProduct],
                                               toolchain: "Xcode 98.0 Build version 98A1"))
        XCTAssertTrue(result.output.contains("the runner's Xcode (Xcode 99.0 Build version 99A1) differs from this Mac's"), result.output)
        XCTAssertFalse(result.output.contains("installed the prebuilt"), result.output)
        XCTAssertEqual(result.built, allProducts)
    }

    func testRunnerWithoutBuildDirectoryBuilds() throws {
        let runner = try Runner()
        try runner.stageProduct(RemoteAlignPlan.mcpProduct, "mcp")
        let result = try runner.run(runner.plan(shipped: ["fleetest", RemoteAlignPlan.mcpProduct]))
        XCTAssertTrue(result.output.contains("the runner has no build directory (.build/debug) yet"), result.output)
        XCTAssertEqual(result.built, allProducts)
    }

    /// 無効な計画(`.none`)は従来と同じスクリプト(取り込みの文を持たない)
    func testNonePlanKeepsTheLegacyScript() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice", home: "/Users/ci")
        let script = RemoteAlignPlan.buildScript(layout: layout, revision: "9655a21", digest: "d1", developerDir: nil, prebuilt: .none)
        XCTAssertFalse(script.contains("ft_install"))
        XCTAssertTrue(script.contains(" && swift build --product fleetest && "))
    }

    /// 取り込みの文の形(原子的な差し替え・ランナー側の照合・書式の妥当性)
    func testInstallScriptShape() throws {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice", home: "/Users/ci")
        let plan = AlignPrebuilt.Plan(shipped: ["fleetest"], reasons: ["fleetest-mcp": "it's old"],
                                      localToolchain: "Xcode 1", stagingDirectory: "/tmp/fleetest-remote-align.ABCDEFGH")
        let script = RemoteAlignPlan.buildScript(layout: layout, revision: "9655a21", digest: "d1", developerDir: nil, prebuilt: plan)
        XCTAssertTrue(script.contains("ft_stage='/tmp/fleetest-remote-align.ABCDEFGH'"))
        XCTAssertTrue(script.contains("\"$ft_stage/fleetest\" api macho-check \"$ft_is\""), "ランナー側の照合")
        XCTAssertTrue(script.contains("mv -f \"$ft_tmp\" \"$ft_prod/$ft_ip\""), "一時名からの mv(原子的)")
        XCTAssertTrue(script.contains("ft_prod=$(cd .build/debug"), "`.build/debug` の実体を解決する")
        XCTAssertTrue(script.contains("{ ft_install fleetest || swift build --product fleetest; }"))
        XCTAssertTrue(script.contains("ft_install \"$ft_p\" || swift build --product \"$ft_p\""), "省かない製品は取り込みかビルド")
        XCTAssertTrue(script.contains("'fleetest-mcp') ft_why='it'\\''s old'"), script)
        let rec = try XCTUnwrap(script.range(of: "> \"$ft_rec\""))
        let install = try XCTUnwrap(script.range(of: "ft_install fleetest ||"))
        XCTAssertLessThan(install.lowerBound, rec.lowerBound, "記録は取り込み・ビルドの後")
        XCTAssertEqual(try Shell.run(["/bin/sh", "-n", "-c", script]).status, 0)
    }

    /// 送った製品はアライン後に名指しで消える(ヘルパーのディレクトリは残らない)
    func testAlignCommandCleansStagedProducts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = RemoteLayout(base: root.appendingPathComponent("runner").path, issuer: "alice", home: root.path)
        try FileManager.default.createDirectory(atPath: layout.toolRoot, withIntermediateDirectories: true)
        let dir = root.appendingPathComponent("maintenance")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let helper = dir.appendingPathComponent("fleetest")
        try Data("#!/bin/sh\nexit 73\n".utf8).write(to: helper)
        try Data("x".utf8).write(to: dir.appendingPathComponent(RemoteAlignPlan.mcpProduct))
        let plan = AlignPrebuilt.Plan(shipped: ["fleetest", RemoteAlignPlan.mcpProduct], reasons: [:], localToolchain: "X",
                                      stagingDirectory: dir.path)
        let command = RemoteSetupPlan.alignRevisionCommand(layout: layout, revision: "9655a21", digest: "d1", helperPath: helper.path,
                                                           developerDir: nil, prebuilt: plan)
        XCTAssertTrue(command.contains("\"$ft_align_helper_dir\"/\(RemoteAlignPlan.mcpProduct)"), command)
        let result = try Shell.run(["/bin/sh", "-c", command])
        XCTAssertEqual(result.status, 73, result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "ヘルパーも送った製品も残さない")
    }

    // MARK: - 配線(ソース走査)

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// 狙い: ヘルパー(`fleetest`)を別に scp し直す変異・`fleetest` を送る一覧へ入れる変異で落ちる(同じファイルを二度送らない)
    func testHelperIsReusedAsTheInstalledFleetest() throws {
        let align = try source("Sources/fleetest/RemoteAlign.swift")
        XCTAssertEqual(align.components(separatedBy: "setupSCPBase").count - 1, 2,
                       "scp の組み立て = 宣言1 + ヘルパーと製品を一緒に送る1(ここが増えたら二重に送っていないか見る)")
        XCTAssertTrue(align.contains("setupSCPBase + [executable.path] + selection.files.map(\\.path)"))
        let selection = try source("Sources/fleetest/RemoteAlignPrebuilt.swift")
        XCTAssertTrue(selection.contains("decision == .ship, product != \"fleetest\""), "fleetest はヘルパー自身")
        let plan = try source("Sources/FTRemote/RemoteAlignPlan.swift")
        XCTAssertTrue(plan.contains("$ft_stage/fleetest"), "取り込みもヘルパーのファイルを使う")
    }
}
