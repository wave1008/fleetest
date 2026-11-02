// 中断で止めたブリッジのビルドは、ビルドの失敗にも署名の診断にも回さず、中断と分かるエラーで返す。

import XCTest
import FTCore
@testable import FTBridgeClient

final class BuildInterruptedLauncherTests: XCTestCase {
    override func setUp() { BuildAbort.resetForTesting() }
    override func tearDown() { BuildAbort.resetForTesting() }

    private let signingLog = "error: Signing for \"FleetestRunner\" requires a development team. Select a development team"

    /// 破ると落ちる: aborted の分岐を外すと commandFailed / codeSigningIncomplete に化ける
    func testAbortedXcodebuildIsNotReportedAsABuildFailureOrSigningProblem() {
        for log in ["BUILD FAILED\n** BUILD INTERRUPTED **", signingLog] {
            let error = BridgeLauncher.buildForTestingError(
                aborted: true, output: log, tail: log, writeLog: { _ in nil })
            guard case .buildInterrupted(let command) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(command, "xcodebuild build-for-testing")
            XCTAssertFalse(error.localizedDescription.contains("failed"))
        }
    }

    /// 中断でなければ従来どおり(常に中断へ倒す変異を落とす)
    func testNotAbortedKeepsTheOrdinaryClassification() {
        let plain = BridgeLauncher.buildForTestingError(
            aborted: false, output: "BUILD FAILED", tail: "BUILD FAILED", writeLog: { _ in nil })
        guard case .commandFailed = plain else { return XCTFail("\(plain)") }
    }

    /// build.sh が中断で止まった回は buildInterrupted(buildFailed ではない)
    func testInAppBuildStoppedByTheInterruptionIsInterrupted() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ft-buildint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("InAppBridge"), withIntermediateDirectories: true)
        try "exit 1\n".write(to: root.appendingPathComponent("InAppBridge/build.sh"), atomically: true, encoding: .utf8)
        let launcher = InAppLauncher(repoRoot: root, udid: "U", port: 9999)

        XCTAssertThrowsError(try launcher.buildIfNeeded()) { error in
            guard case InAppLauncherError.buildFailed = error else { return XCTFail("前提: 中断なしは buildFailed: \(error)") }
        }
        BuildAbort.abortAll(kill: false)
        XCTAssertThrowsError(try launcher.buildIfNeeded()) { error in
            guard case InAppLauncherError.buildInterrupted = error else { return XCTFail("\(error)") }
            XCTAssertFalse(error.localizedDescription.contains("failed"))
            XCTAssertNil(StepExecutor.failureKind(thrown: error))
        }
    }
}
