import XCTest
@testable import FTBridgeClient
import FTCore

/// 止まった run の供給は、ランナーの起動・引き取り・起こし直しを撃たず、起動の待ちも打ち切る
/// (37周目 duo F1: シナリオのビルドが落ちて「Stopping」と言った後も、iOS の供給が2台にランナーを起動・起こし直し、
/// 180 秒待って dispatch.lock を約5分持った。止まれの印は `buildIOSWorkers` が返った後にしか見ていなかった)
final class SupplyAbandonBridgeStartTests: XCTestCase {

    func testTheStartupWaitEndsAtOnceWhenTheRunHasStopped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("abandon-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // 誰も待ち受けていないポート = 印が無ければ timeout まで待ち続ける
        let launcher = BridgeLauncher(repoRoot: root, device: "00000000-0000-0000-0000-000000000000", port: 1, physical: false)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            try await launcher.waitUntilReady(timeout: 30, isStopped: { true })
            XCTFail("止まった run の待ちが返った")
        } catch LauncherError.abandoned {
        } catch {
            XCTFail("打ち切り以外で抜けた: \(error)")
        }
        XCTAssertLessThan(clock.now - start, .seconds(5), "印を見ずに待った")
    }

    func testOnlyStartsAndTakeoversAreRefusedOnceStopped() {
        let launch = BridgeProvisioner.BridgePlan.launch(port: 8123, needsInstall: false, stopStalePort: nil, reclaimInApp: false)
        XCTAssertTrue(BridgeProvisioner.startIsAbandoned(launch, stopped: true))
        XCTAssertTrue(BridgeProvisioner.startIsAbandoned(.adopt(port: 8123), stopped: true))
        XCTAssertFalse(BridgeProvisioner.startIsAbandoned(.reuse(port: 8123), stopped: true), "再利用は撃たないので通す")
        XCTAssertFalse(BridgeProvisioner.startIsAbandoned(launch, stopped: false))
    }

    /// 打ち切った台は「起動の失敗」と言わない(陽性対照で8台が「❌ … did not become ready in time」と出た)
    func testAnAbandonedDeviceIsNotReportedAsAStartupFailure() {
        let abandoned = BridgeProvisionerError.notReady(port: 8124, underlying: LauncherError.abandoned)
        XCTAssertTrue(BridgeProvisioner.isAbandoned(abandoned))
        XCTAssertFalse(BridgeProvisioner.isAbandoned(BridgeProvisionerError.notReady(
            port: 8124, underlying: LauncherError.timedOut("no response", "/tmp/log"))))
        XCTAssertTrue(BridgeProvisioner.abandonedLine(name: "-01").hasPrefix("⏹ -01:"))
    }

    /// 印の配線(緑の run では1度も通らない経路なので、ソースで固定する)
    func testTheStopSignalReachesEveryStartupWaitOfTheSupply() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let provisioner = try String(contentsOf: root.appendingPathComponent("Sources/FTBridgeClient/BridgeProvisioner.swift"),
                                     encoding: .utf8)
        let waits = provisioner.components(separatedBy: "launcher.waitUntilReady(").dropFirst()
        XCTAssertGreaterThanOrEqual(waits.count, 4, "走査が届いていない")
        for (index, call) in waits.enumerated() {
            XCTAssertTrue(String(call.prefix(400)).contains("isStopped: isStopped"), "\(index + 1) 本目の起動の待ちに止まれの印が無い")
        }
        let lanes = try String(contentsOf: root.appendingPathComponent("Sources/fleetest/ProfileSupplyLanes.swift"), encoding: .utf8)
        XCTAssertTrue(lanes.contains("mayEraseSimulatorForRecovery: true, isStopped: isStopped"),
                      "供給のレーンが buildIOSWorkers に止まれの印を渡していない")
        let factory = try String(contentsOf: root.appendingPathComponent("Sources/FTAndroid/ProfileWorkerFactory.swift"),
                                 encoding: .utf8)
        XCTAssertTrue(factory.contains("isStopped: isStopped)"), "buildIOSWorkers が BridgeProvisioner に印を渡していない")
    }
}
