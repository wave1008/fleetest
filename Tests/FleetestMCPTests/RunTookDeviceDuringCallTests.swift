// ft_run_scenario の使用中の確認は開始時だけだったので、呼び出しの途中で fleetest run が台を取ると、警告なしの 503/422 の赤を
// 作成者は「自分のシナリオがアプリを落とした」と読んだ。終わりにも確かめて言う

import XCTest
@testable import fleetest_mcp

final class RunTookDeviceDuringCallTests: XCTestCase {
    func testNoteNamesTheRunAndTheLikelyEffect() {
        let note = MCPServer.runTookDeviceDuringCallNote(holderPID: 4242)
        XCTAssertTrue(note.hasPrefix("⚠️ a fleetest run (pid 4242) started using this device during this call"), note)
        XCTAssertTrue(note.contains("reinstalls and relaunches the app"), note)
    }

    /// 終わりの確認は応答の行を作る所(`HealSourceWriteBack.run` の後)にあり、開始時の使用者と比べる = 開始時から握っていた run は
    /// 開始時の警告で言っているので二度言わない
    func testRunScenarioChecksTheHolderAgainAtTheEnd() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest-mcp/MCPServer+ScenarioTools.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "runHolderAtStart = RunLease.holderPID(stateDir: stateDir, key: deviceKey)"))
        let heal = try XCTUnwrap(source.range(of: "HealSourceWriteBack.run(suggestions: healSuggestions"))
        let end = try XCTUnwrap(source.range(of: "holder != runHolderAtStart"))
        XCTAssertLessThan(start.lowerBound, heal.lowerBound)
        XCTAssertLessThan(heal.lowerBound, end.lowerBound)
        XCTAssertTrue(source.contains("lines.append(Self.runTookDeviceDuringCallNote(holderPID: holder))"))
    }
}
