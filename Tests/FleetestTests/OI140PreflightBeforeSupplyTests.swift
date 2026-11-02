// OI-140: 一覧が既にある回(ビルド済み)の名指しの打ち間違いは、デバイスの供給より前に断る(`run` と `api run` の両方)。
// ビルドが要る回は一覧が無く、供給をビルドと並行に起こす作りなので従来どおり(ScenarioPreflight の宣言参照)。

import XCTest

final class OI140PreflightBeforeSupplyTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/fleetest/\(name)"), encoding: .utf8)
    }

    private func offset(of needle: String, in text: String) throws -> Int {
        let range = try XCTUnwrap(text.range(of: needle), "\(needle) が見つからない")
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }

    func testRunChecksTheNamesBeforeThePreparedSupply() throws {
        let text = try source("Fleetest.swift")
        XCTAssertLessThan(try offset(of: "ScenarioPreflight.rejectUnknownScenarios(", in: text),
                          try offset(of: "ProfileRunner.prepareSupply(", in: text))
    }

    func testApiRunChecksTheNamesBeforeTheSupplyProgressIsCreated() throws {
        let text = try source("ApiRunCommand.swift")
        XCTAssertLessThan(try offset(of: "ScenarioPreflight.rejectUnknownScenarios(", in: text),
                          try offset(of: "let supplyProgress = RunSupplyProgress()", in: text))
    }
}
