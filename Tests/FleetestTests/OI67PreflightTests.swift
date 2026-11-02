// 書けない --report-dir を始める前に断る・--debug の「解決後に1本」の文言を事前検査と本検査で共有する。

import FTCore
import Foundation
import XCTest
@testable import fleetest

final class OI67PreflightTests: XCTestCase {
    func testDebugNeedsOneScenarioMessageCarriesTheCount() {
        XCTAssertTrue(ScenarioPreflight.debugNeedsOneScenarioMessage(resolvedCount: 3).contains("resolves to 3"))
    }
    func testReportDirThatIsAFileIsRejected() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ft-reportdir-\(UUID().uuidString)")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try RunCommonOptions.rejectUnwritableReportDir(file.path))
        XCTAssertThrowsError(try RunCommonOptions.rejectUnwritableReportDir(file.appendingPathComponent("sub").path))
        XCTAssertNoThrow(try RunCommonOptions.rejectUnwritableReportDir(NSTemporaryDirectory()))
        XCTAssertNoThrow(try RunCommonOptions.rejectUnwritableReportDir(nil))
    }
}
