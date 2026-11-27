// 親がビルドして送ったシナリオ実行バイナリを子が使う仕組み(`PrebuiltScenarios` / `ScenarioHost.usePrebuilt`)の検証。
// 送る判定は純粋関数・子の受け入れは FT_PACKAGE_ROOT を一時の repo へ向けて見る(ScenarioHostSkipBuildStaleTests と同じ口)。
// override はプロセス内の static なので tearDown で必ず捨てる。

import XCTest
@testable import FTCore

final class PrebuiltScenariosTests: XCTestCase {

    private var savedPackageRoot: String?
    private var repoRoot: URL!
    private var project: TestProject!

    override func setUpWithError() throws {
        savedPackageRoot = ProcessInfo.processInfo.environment["FT_PACKAGE_ROOT"]
        repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-prebuilt-\(UUID().uuidString)", isDirectory: true)
        project = TestProject(name: "Foo", rootURL: repoRoot.appendingPathComponent("TestProjects/Foo"))
        try FileManager.default.createDirectory(at: project.scenariosDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoRoot.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0".write(to: repoRoot.appendingPathComponent("Package.swift"),
                                                atomically: true, encoding: .utf8)
        setenv("FT_PACKAGE_ROOT", repoRoot.path, 1)
        ScenarioHost.prebuiltRunners.withLock { $0.removeAll() }
    }

    override func tearDownWithError() throws {
        ScenarioHost.prebuiltRunners.withLock { $0.removeAll() }
        if let savedPackageRoot { setenv("FT_PACKAGE_ROOT", savedPackageRoot, 1) } else { unsetenv("FT_PACKAGE_ROOT") }
        try? FileManager.default.removeItem(at: repoRoot)
    }

    /// 実行可能な偽のバイナリ(中身は使わない)。`name` が製品名と違えば「別のプロジェクトのバイナリ」
    private func makeBinary(named name: String, executable: Bool = true) throws -> URL {
        let dir = repoRoot.appendingPathComponent("staged", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        return url
    }

    // MARK: - 親の判定(純粋関数)

    private func conditions(fresh: Bool = true, digest: Bool? = true, toolchain: Bool? = true,
                            workingTree: Bool = true) -> PrebuiltScenarios.Conditions {
        .init(localBinaryFresh: fresh, digestMatches: digest, toolchainIdentical: toolchain, toolFromWorkingTree: workingTree)
    }

    func testSendsOnlyWhenEveryConditionHolds() {
        XCTAssertEqual(PrebuiltScenarios.decide(conditions()), .send)
    }

    func testEachFailedConditionSkipsWithAReason() {
        for failing in [conditions(fresh: false), conditions(digest: false), conditions(digest: nil),
                        conditions(toolchain: false), conditions(toolchain: nil), conditions(workingTree: false)] {
            guard case .skip(let reason) = PrebuiltScenarios.decide(failing) else {
                return XCTFail("must not send: \(failing)")
            }
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func testStagedPathKeepsTheProductNameAsFileName() {
        XCTAssertEqual(PrebuiltScenarios.stagedPath(workDir: "/w", stamp: "S", productName: "fleetest-scenarios-Foo"),
                       "/w/.fleetest/dispatch/S/prebuilt/fleetest-scenarios-Foo")
        XCTAssertEqual(PrebuiltScenarios.args(remotePath: "/p", originRoot: "/o"),
                       ["--prebuilt-scenarios", "/p", "--prebuilt-origin-root", "/o"])
    }

    func testStripOriginRoot() {
        XCTAssertEqual(PrebuiltScenarios.stripOriginRoot("/Users/a/pkg/TestProjects/Foo/scenarios/X.swift", originRoot: "/Users/a/pkg"),
                       "TestProjects/Foo/scenarios/X.swift")
        XCTAssertEqual(PrebuiltScenarios.stripOriginRoot("/Users/a/pkg2/X.swift", originRoot: "/Users/a/pkg"),
                       "/Users/a/pkg2/X.swift", "接頭辞はディレクトリ境界で比べる")
        XCTAssertEqual(PrebuiltScenarios.stripOriginRoot("/x/y.swift", originRoot: nil), "/x/y.swift")
    }

    // MARK: - 子の受け入れ

    func testChildAcceptsThePrebuiltBinarySkipsTheBuildAndRunsIt() throws {
        let binary = try makeBinary(named: project.productName)
        var logs: [String] = []
        XCTAssertTrue(ScenarioHost.usePrebuilt(project: project, binary: binary, originRoot: "/origin", toolRoot: "/runner/fleetest", log: { logs.append($0) }))
        XCTAssertTrue(logs.contains { $0.hasPrefix("→ Using the prebuilt scenarios sent by the parent") }, "\(logs)")
        XCTAssertEqual(try ScenarioHost.runnerURL(project: project).path, binary.path)
        XCTAssertFalse(ScenarioHost.buildNeeded(project: project))
        // swift build を呼べば一時 repo では失敗して投げる。省けていれば何も出さず戻る
        var buildLogs: [String] = []
        XCTAssertNoThrow(try ScenarioHost.build(project: project, log: { buildLogs.append($0) },
                                                willBuild: { XCTFail("must not build") }))
        XCTAssertEqual(buildLogs, [])
        XCTAssertEqual(ScenarioHost.childEnvironment(base: [:])[ProcessEnvironmentKey.scenarioOriginRoot], "/origin")
        // 送られたバイナリは置き場所からツールを辿れない = シナリオへツールのルートを渡す(渡さないと repo root detection failed で全部赤)。
        // 外で指定済みなら上書きしない
        XCTAssertEqual(ScenarioHost.childEnvironment(base: [:])[ProcessEnvironmentKey.toolRoot], "/runner/fleetest")
        XCTAssertEqual(ScenarioHost.childEnvironment(base: [ProcessEnvironmentKey.toolRoot: "/given"])[ProcessEnvironmentKey.toolRoot], "/given")
    }

    func testChildRefusesAMissingFileAndFallsBackToBuilding() {
        var logs: [String] = []
        let missing = repoRoot.appendingPathComponent("staged/\(project.productName)")
        XCTAssertFalse(ScenarioHost.usePrebuilt(project: project, binary: missing, originRoot: nil, toolRoot: nil, log: { logs.append($0) }))
        XCTAssertNil(ScenarioHost.prebuiltRunner(for: project))
        XCTAssertTrue(ScenarioHost.buildNeeded(project: project), "登録が無ければ今までどおりビルドが要る")
        XCTAssertNil(ScenarioHost.childEnvironment(base: [:])[ProcessEnvironmentKey.scenarioOriginRoot])
        XCTAssertNil(ScenarioHost.childEnvironment(base: [:])[ProcessEnvironmentKey.toolRoot], "送られていなければ環境を変えない")
        XCTAssertEqual(logs.count, 1)
    }

    func testChildRefusesANonExecutableFileAndAnotherProductsBinary() throws {
        XCTAssertFalse(ScenarioHost.usePrebuilt(project: project, binary: try makeBinary(named: project.productName, executable: false),
                                                originRoot: nil, toolRoot: nil, log: nil))
        XCTAssertFalse(ScenarioHost.usePrebuilt(project: project, binary: try makeBinary(named: "fleetest-scenarios-Other"),
                                                originRoot: nil, toolRoot: nil, log: nil), "別のプロジェクトのバイナリは受けない")
        XCTAssertNil(ScenarioHost.prebuiltRunner(for: project))
    }

    func testOverrideOfOneProjectDoesNotAnswerForAnother() throws {
        _ = ScenarioHost.usePrebuilt(project: project, binary: try makeBinary(named: project.productName), originRoot: nil, toolRoot: nil, log: nil)
        let other = TestProject(name: "Bar", rootURL: repoRoot.appendingPathComponent("TestProjects/Bar"))
        XCTAssertNil(ScenarioHost.prebuiltRunner(for: other))
    }

    // MARK: - 走査(型の効かない継ぎ目)

    private static var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: Self.sources.appendingPathComponent(relative), encoding: .utf8)
    }

    /// 実行バイナリの場所を決めるのは `runnerURL` の1箇所(製品名でパスを組む場所を他へ増やさない)
    func testRunnerPathIsDecidedInOnePlace() throws {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.components(separatedBy: "\n")
            where line.contains("appendingPathComponent(project.productName)") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                offenders.append(url.lastPathComponent)
            }
        }
        XCTAssertEqual(offenders, Array(repeating: "ScenarioHost.swift", count: 3), "runnerURL の3つの候補(.build/debug・隣・--show-bin-path)だけ")
        let host = try read("FTCore/ScenarioHost.swift")
        let body = try XCTUnwrap(host.range(of: "public static func runnerURL(project: TestProject) throws -> URL {"))
        XCTAssertTrue(host[body.upperBound...].prefix(160).contains("prebuiltRunner(for: project)"), "登録を最初に見る")
    }

    func testReportPathsAndChildEnvironmentCarryTheOriginRoot() throws {
        XCTAssertTrue(try read("FTDSL/FTRuntime.swift").contains("PrebuiltScenarios.stripOriginRoot"))
        XCTAssertTrue(try read("FTCore/ScenarioHost.swift").contains("env[ProcessEnvironmentKey.scenarioOriginRoot] = prebuiltOriginRoot"))
        XCTAssertTrue(ProcessEnvironmentKey.scenarioOriginRoot.hasPrefix("FT_"),
                      "サンドボックスの子へ渡るのは FT_ 接頭辞の鍵だけ(ScenarioSandbox.inheritedEnvironmentPrefixes)")
    }
}
