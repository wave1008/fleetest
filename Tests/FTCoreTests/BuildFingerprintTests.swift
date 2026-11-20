import XCTest
@testable import FTCore

final class BuildFingerprintTests: XCTestCase {
    var repoRoot: URL!
    var scenariosDir: URL!

    override func setUpWithError() throws {
        repoRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FTCoreTests-repo-\(UUID().uuidString)")
        scenariosDir = repoRoot.appendingPathComponent("scenarios")
        try FileManager.default.createDirectory(
            at: repoRoot.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: scenariosDir, withIntermediateDirectories: true)
        try "// Package.swift".write(
            to: repoRoot.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "{}".write(
            to: repoRoot.appendingPathComponent("Package.resolved"), atomically: true, encoding: .utf8)
        try "// xx".write(
            to: repoRoot.appendingPathComponent("Sources/xx.swift"), atomically: true, encoding: .utf8)
        try "// yy".write(
            to: scenariosDir.appendingPathComponent("yy.swift"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repoRoot)
    }

    func testSameStateProducesSameFingerprint() {
        let a = BuildFingerprint.compute(repoRoot: repoRoot, scenariosDir: scenariosDir)
        let b = BuildFingerprint.compute(repoRoot: repoRoot, scenariosDir: scenariosDir)
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
    }

    func testAddingFileChangesFingerprint() throws {
        let before = BuildFingerprint.compute(repoRoot: repoRoot, scenariosDir: scenariosDir)
        try "// zz".write(
            to: repoRoot.appendingPathComponent("Sources/zz.swift"), atomically: true, encoding: .utf8)
        let after = BuildFingerprint.compute(repoRoot: repoRoot, scenariosDir: scenariosDir)
        XCTAssertNotEqual(before, after)
    }

    func testMtimeOnlyChangeChangesFingerprint() throws {
        let before = BuildFingerprint.compute(repoRoot: repoRoot, scenariosDir: scenariosDir)
        let path = repoRoot.appendingPathComponent("Sources/xx.swift").path
        let newDate = Date().addingTimeInterval(3600)
        try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: path)
        let after = BuildFingerprint.compute(repoRoot: repoRoot, scenariosDir: scenariosDir)
        XCTAssertNotEqual(before, after, "内容・サイズが同じでも mtime 変更で変わるはず")
    }

    func testToolchainIdentityChangesFingerprint() {
        let a = BuildFingerprint.compute(
            repoRoot: repoRoot, scenariosDir: scenariosDir, toolchainIdentity: "toolchain-a")
        let b = BuildFingerprint.compute(
            repoRoot: repoRoot, scenariosDir: scenariosDir, toolchainIdentity: "toolchain-b")
        XCTAssertNotEqual(a, b)
    }

    func testStoreAndStoredRoundTrip() {
        BuildFingerprint.store("abc123", productName: "fleetest-scenarios-Sample", repoRoot: repoRoot)
        let stored = BuildFingerprint.stored(
            productName: "fleetest-scenarios-Sample", repoRoot: repoRoot)
        XCTAssertEqual(stored, "abc123")
    }

    // ---- 外部パッケージ構成(受け手・ランナー機の WORK_DIR: Sources/ 無し・ツールはパス依存) ----

    /// WORK_DIR の隣にツールのクローン(Sources/ 付き)を作り、Package.swift にパス依存を書く
    private func makeExternalLayout(dependencyLine: (URL) -> String) throws -> URL {
        try FileManager.default.removeItem(at: repoRoot.appendingPathComponent("Sources"))
        let toolRoot = repoRoot.appendingPathComponent("tool-clone")
        try FileManager.default.createDirectory(
            at: toolRoot.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try "// core".write(
            to: toolRoot.appendingPathComponent("Sources/Core.swift"), atomically: true, encoding: .utf8)
        try "dependencies: [\n    \(dependencyLine(toolRoot))\n]".write(
            to: repoRoot.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        return toolRoot
    }

    func testMissingSourcesDirStillProducesFingerprint() throws {
        try FileManager.default.removeItem(at: repoRoot.appendingPathComponent("Sources"))
        let a = BuildFingerprint.compute(repoRoot: repoRoot, scenariosDir: scenariosDir)
        XCTAssertNotNil(a, "Sources/ が無いだけで nil にすると、外部パッケージ構成は毎回ビルドする")
        XCTAssertEqual(a, BuildFingerprint.compute(repoRoot: repoRoot, scenariosDir: scenariosDir))
    }

    func testMissingScenariosDirReturnsNil() throws {
        try FileManager.default.removeItem(at: scenariosDir)
        XCTAssertNil(BuildFingerprint.compute(repoRoot: repoRoot, scenariosDir: scenariosDir))
    }

    func testPathDependencySourceChangeChangesFingerprint() throws {
        let toolRoot = try makeExternalLayout { #".package(path: "\#($0.path)"),"# }
        let before = BuildFingerprint.compute(repoRoot: repoRoot, scenariosDir: scenariosDir)
        XCTAssertNotNil(before)
        XCTAssertEqual(before, BuildFingerprint.compute(repoRoot: repoRoot, scenariosDir: scenariosDir))
        try "// core changed".write(
            to: toolRoot.appendingPathComponent("Sources/Core.swift"), atomically: true, encoding: .utf8)
        let after = BuildFingerprint.compute(repoRoot: repoRoot, scenariosDir: scenariosDir)
        XCTAssertNotNil(after)
        XCTAssertNotEqual(before, after, "ツール本体を更新したのに古いシナリオ実行バイナリを使い続ける")
    }

    func testRelativePathDependencyIsResolvedAgainstRepoRoot() throws {
        let toolRoot = try makeExternalLayout { _ in #".package(name: "tool", path: "tool-clone"),"# }
        XCTAssertEqual(BuildFingerprint.pathDependencyRoots(repoRoot: repoRoot).map(\.path),
                       [toolRoot.standardizedFileURL.path])
        let before = BuildFingerprint.compute(repoRoot: repoRoot, scenariosDir: scenariosDir)
        try "// added".write(
            to: toolRoot.appendingPathComponent("Sources/Added.swift"), atomically: true, encoding: .utf8)
        XCTAssertNotEqual(before, BuildFingerprint.compute(repoRoot: repoRoot, scenariosDir: scenariosDir))
    }

    func testPathDependencyWithoutSourcesReturnsNil() throws {
        let toolRoot = try makeExternalLayout { #".package(path: "\#($0.path)"),"# }
        try FileManager.default.removeItem(at: toolRoot.appendingPathComponent("Sources"))
        XCTAssertNil(BuildFingerprint.compute(repoRoot: repoRoot, scenariosDir: scenariosDir),
                     "依存の先が読めないなら判定材料が無い(常にビルドする側へ)")
    }

    func testCommentedOutPathDependencyIsIgnored() throws {
        _ = try makeExternalLayout { _ in #"// .package(path: "/nonexistent/clone"),"# }
        XCTAssertEqual(BuildFingerprint.pathDependencyRoots(repoRoot: repoRoot), [])
        XCTAssertNotNil(BuildFingerprint.compute(repoRoot: repoRoot, scenariosDir: scenariosDir))
    }

    /// 警告の根拠に名指すパス: 変わった行・足された行・消えた行の最初(名前の順)。食い違いが無ければ nil
    func testChangedEntryNamesTheFirstDifferingPath() {
        let before = ["Package.resolved\t100\t5", "a.swift\t1\t1", "toolchain\tX|1"]
        XCTAssertNil(BuildFingerprint.changedEntry(stored: before, current: before))
        XCTAssertEqual(BuildFingerprint.changedEntry(
            stored: before, current: ["Package.resolved\t200\t5", "a.swift\t1\t1", "toolchain\tX|1"]), "Package.resolved")
        XCTAssertEqual(BuildFingerprint.changedEntry(stored: before, current: before + ["b.swift\t2\t2"]), "b.swift")
        XCTAssertEqual(BuildFingerprint.changedEntry(stored: before, current: Array(before.dropFirst())), "Package.resolved")
        XCTAssertEqual(BuildFingerprint.changedEntry(
            stored: before, current: ["Package.resolved\t100\t5", "a.swift\t1\t1", "toolchain\tY|1"]), "toolchain")
    }

    /// 材料の行は指紋と同じ瞬間の材料(digest と行が別々の時点を指さない)
    func testSnapshotDigestMatchesCompute() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bf-\(UUID().uuidString)")
        let scenarios = root.appendingPathComponent("TestProjects/p/scenarios")
        try FileManager.default.createDirectory(at: scenarios, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(to: scenarios.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        let snap = try XCTUnwrap(BuildFingerprint.snapshot(repoRoot: root, scenariosDir: scenarios, toolchainIdentity: "T"))
        XCTAssertEqual(snap.digest, BuildFingerprint.compute(repoRoot: root, scenariosDir: scenarios, toolchainIdentity: "T"))
        XCTAssertEqual(snap.lines.last, "toolchain\tT")
        XCTAssertTrue(snap.lines.contains { $0.contains("TestProjects/p/scenarios/a.swift\t") })
    }
}
