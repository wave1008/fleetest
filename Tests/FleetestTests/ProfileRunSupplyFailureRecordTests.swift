// OI-99: `fleetest run` の供給段の失敗は、サービスのログと servicesWarnings を run の記録に残す(api run の catch と対)。
// 型では守れない継ぎ目(箱を渡し忘れても緑のまま記録が黙って欠ける)なのでソース走査で固定する。

import XCTest
@testable import fleetest

final class ProfileRunSupplyFailureRecordTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testSupplyFailureCatchSavesServiceLogsAndWarnings() throws {
        let text = try source("Sources/fleetest/Fleetest.swift")
        XCTAssertTrue(text.contains("servicesBox: servicesBox"), "ProfileRunner.run へ箱を渡す")
        XCTAssertTrue(text.contains("failedServices?.saveLogs(to: recorder.runDir)"), "失敗の catch でログを残す")
        XCTAssertTrue(text.contains("servicesWarnings: failedServices?.warnings ?? []"), "失敗の catch で警告を残す")
    }

    func testProfileRunnerFillsTheBox() throws {
        let text = try source("Sources/fleetest/ProfileRunner.swift")
        XCTAssertTrue(text.contains("servicesBox?.session = servicesSession"))
    }
}
