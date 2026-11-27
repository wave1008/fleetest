// 親(RemoteRunDispatcher)が送り、子(run / api run)が受ける配線の走査。**送る口は performDispatch の1箇所**
// (run・api run・fan-out の子 = `--runner` のディスパッチは全部ここを通る)。型の効かない継ぎ目だけを固定する。

import XCTest
import ArgumentParser
@testable import fleetest

final class ChildPrebuiltScenariosWiringTests: XCTestCase {

    private func read(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testDispatcherAppendsThePrebuiltArgsToEveryChildCommandLine() throws {
        let text = try read("Sources/fleetest/RemoteRunDispatcher.swift")
        XCTAssertEqual(text.components(separatedBy: "+ prebuiltArgs").count - 1, 1)
        XCTAssertTrue(text.contains("let fleetestArgs = buildArgs(remoteReportDir, remoteWorkspace, remoteJUnitPath, lockLink?.remotePath) + prebuiltArgs"))
        // buildArgs を使うのは dispatch / dispatchApi の2経路だけで、どちらも performDispatch を通る
        XCTAssertEqual(text.components(separatedBy: "try await performDispatch(").count - 1, 2)
        // 送る判定は PrebuiltScenarios.decide を通る(全体の要約の一致を要求する材料は適合チェックの1箇所)
        XCTAssertTrue(text.contains("PrebuiltScenarios.decide("))
        XCTAssertTrue(text.contains("digestMatches: remoteTool?.digest.map { $0 == localTool.digest }"))
    }

    func testBothRunCommandsAcceptTheHiddenFlagsAndInstallBeforeBuilding() throws {
        for (file, buildNeedle) in [("Sources/fleetest/Fleetest.swift", "ScenarioHost.buildNeeded(project: testProject)"),
                                    ("Sources/fleetest/ApiRunCommand.swift", "ScenarioHost.build(project: testProject")] {
            let text = try read(file)
            XCTAssertTrue(text.contains("@OptionGroup var prebuilt: ChildPrebuiltScenariosOption"), file)
            let install = try XCTUnwrap(text.range(of: "prebuilt.install(project: testProject"), file)
            let build = try XCTUnwrap(text.range(of: buildNeedle), file)
            XCTAssertLessThan(install.lowerBound, build.lowerBound, "\(file): ビルド判定より前に登録する")
        }
    }

    func testFlagsAreHiddenFromHelpAndParse() throws {
        for help in [RunScenarios.helpMessage(), ApiRunCommand.helpMessage()] {
            XCTAssertFalse(help.contains("prebuilt"), "内部フラグはヘルプに出さない(RunCommandFlagParityTests の表の対象外)")
        }
        let parsed = try RunScenarios.parse(["--project", "P", "--prebuilt-scenarios", "/x/y", "--prebuilt-origin-root", "/o"])
        XCTAssertEqual(parsed.prebuilt.path, "/x/y")
        XCTAssertEqual(parsed.prebuilt.originRoot, "/o")
        let api = try ApiRunCommand.parse(["--project", "P", "--scenario", "A.b", "--prebuilt-scenarios", "/x/y", "--prebuilt-origin-root", "/o"])
        XCTAssertEqual(api.prebuilt.path, "/x/y")
    }
}
