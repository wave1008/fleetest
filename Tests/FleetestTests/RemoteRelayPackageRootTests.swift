// リモートの workDir の置換先は受け手のパッケージ(外部構成ではツールのクローンと別の場所 = OI-269①:
// 回収したレポートのパスをクローン側 `fleetest/TestProjects/<proj>/reports` と表示した。実体はパッケージ側)

import XCTest
import FTCore
import FTRemote
@testable import fleetest

final class RemoteRelayPackageRootTests: XCTestCase {

    func testPackageRootIsTwoLevelsAboveTheProject() {
        let project = TestProject(name: "e2ex_and", rootURL: URL(fileURLWithPath: "/work/ws/TestProjects/e2ex_and"))
        XCTAssertEqual(RemoteRunDispatcher.packageRoot(of: project).path, "/work/ws")
    }

    /// 行・JUnit の置換が `localRepoRoot`(ツールのクローン)へ戻っていない
    func testRewritesDoNotTargetTheToolClone() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/RemoteRunDispatcher.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("localRoot: localRepoRoot.path"))
        XCTAssertFalse(source.contains("let localRoot = localRepoRoot.path"))
        XCTAssertEqual(source.components(separatedBy: "localRoot: Self.packageRoot(of: project).path").count - 1, 3)
    }

    /// OI-269②: 可視性検証の切り抜きは回収されるレポートの下へ書かせる(既定の ~/Library/Logs はランナー機に残る)
    func testRemoteRunExportsTheOcclusionDumpDirUnderTheDispatchReports() throws {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice", home: "/Users/ci")
        let dir = layout.dispatchReportDir(stamp: "s1") + "/occlusion"
        let command = RemoteShell.remoteRunCommand(layout: layout, fleetestArgs: ["run"], occlusionDumpDir: dir)
        XCTAssertTrue(command.contains("export FT_OCCLUSION_DUMP_DIR="), command)
        XCTAssertTrue(command.contains(dir), command)
        XCTAssertFalse(RemoteShell.remoteRunCommand(layout: layout, fleetestArgs: ["run"]).contains("FT_OCCLUSION_DUMP_DIR"))
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/RemoteRunDispatcher.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("occlusionDumpDir: layout.dispatchReportDir(stamp: stamp) + \"/occlusion\""))
    }
}
