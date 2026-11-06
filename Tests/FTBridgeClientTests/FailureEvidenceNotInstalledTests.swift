// 入っていないアプリ(前のシナリオの removeApp() 等で消えた)のプロセスが居ないことを「クラッシュしたかも」の証拠にしない。

import XCTest
@testable import FTBridgeClient

final class FailureEvidenceNotInstalledTests: XCTestCase {
    func testNotInstalledAppIsNoCrashEvidence() {
        let evidence = SimulatorAppProcess.failureEvidence(
            bundleID: "com.example", udid: "U", scenarioStartedAt: Date(), recordsProcessGone: false,
            isRunning: { _, _ in false }, notInstalled: { _, _ in true })
        XCTAssertEqual(evidence, [], "入っていないアプリをクラッシュの証拠にした")
    }

    func testRunningAppIsNoEvidenceEitherWay() {
        let evidence = SimulatorAppProcess.failureEvidence(
            bundleID: "com.example", udid: "U", scenarioStartedAt: Date(), recordsProcessGone: false,
            isRunning: { _, _ in true }, notInstalled: { _, _ in false })
        XCTAssertEqual(evidence, [])
    }
}
