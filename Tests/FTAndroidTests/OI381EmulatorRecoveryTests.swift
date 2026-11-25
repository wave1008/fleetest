// Emulator の起動し直しの GPU モード引き継ぎ・同じ AVD の qemu が残るときの断り・
// ゲストの再起動の届き方(時間切れで撃ち重ねない)・回復の戻り値(撃っていない段を返さない)。
// 純粋関数は直接、配線(呼び手が純粋関数を通っていること)はソース走査で固定する。

import XCTest
@testable import FTAndroid

final class OI381EmulatorRecoveryTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - ① GPU モードの引き継ぎ

    func testGpuModeIsReadFromTheLogHeader() {
        let header = "=== 2026-11-25T01:02:03Z emulator -avd Pixel_9 -no-snapshot -no-window -no-boot-anim -no-audio -gpu swiftshader_indirect\nrest"
        XCTAssertEqual(DeviceBooter.gpuMode(inLogHeader: header), "swiftshader_indirect")
    }

    func testGpuModeIsNilWithoutAValueOrWithAnUnsafeValue() {
        XCTAssertNil(DeviceBooter.gpuMode(inLogHeader: "=== t emulator -avd X -no-window"))
        XCTAssertNil(DeviceBooter.gpuMode(inLogHeader: "=== t emulator -avd X -gpu"))
        XCTAssertNil(DeviceBooter.gpuMode(inLogHeader: "=== t emulator -avd X -gpu host;rm"))
        XCTAssertNil(DeviceBooter.gpuMode(inLogHeader: ""))
    }

    /// 既定は引き継ぎ(nil)。"host" へ戻すと CPU 描画指定の台が回復のたびに GPU 描画へ戻る
    func testStartEmulatorDefaultInheritsAndRecoveryCallersDoNotPassHost() throws {
        let booter = try source("Sources/FTAndroid/DeviceBooter.swift")
        XCTAssertTrue(booter.contains("static func startEmulator(avd: String, gpuMode: String? = nil,"),
                      "startEmulator の gpuMode 既定は nil(前回の起動の -gpu を引き継ぐ)")
        let factory = try source("Sources/FTAndroid/ProfileWorkerFactory.swift")
        XCTAssertTrue(factory.contains("DeviceBooter.startEmulator(avd: avd, log: log)"))
        XCTAssertFalse(factory.contains("startEmulator(avd: avd, gpuMode: \"host\""),
                       "停止と起動の回復が GPU モードを host に固定している")
    }

    // MARK: - ② 同じ AVD の qemu が残っていれば起動しない

    func testRefusesWhileTheSameAvdProcessIsRunning() {
        let ps = "/Users/x/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64-headless -avd Pixel_9 -no-window\n"
        XCTAssertNotNil(DeviceBooter.runningProcessRefusal(psOutput: ps, avdID: "Pixel_9"))
    }

    func testDoesNotRefuseForAnotherAvdWhoseNameStartsTheSame() {
        let ps = "qemu-system-aarch64-headless -avd Pixel_9_-010 -no-window\n"
        XCTAssertNil(DeviceBooter.runningProcessRefusal(psOutput: ps, avdID: "Pixel_9_-01"))
    }

    /// ps が読めないとき断ると、ps の不調で全ての起動が止まる
    func testDoesNotRefuseWhenPsIsUnreadable() {
        XCTAssertNil(DeviceBooter.runningProcessRefusal(psOutput: nil, avdID: "Pixel_9"))
    }

    /// 停止直後は qemu が数秒残る: 待っている間に消えれば断らない
    func testStartsWhenTheQemuDisappearsWhileWaiting() async {
        let ps = "qemu-system-aarch64-headless -avd Pixel_9 -no-window\n"
        let reads = LockedCounter()
        let refusal = await DeviceBooter.refusalAfterWaitingForExit(
            avdID: "Pixel_9", graceSeconds: 5, pollNanoseconds: 1_000_000,
            readPS: { reads.increment() < 3 ? ps : "" })
        XCTAssertNil(refusal)
        XCTAssertGreaterThanOrEqual(reads.value, 3)
    }

    /// 待っても残れば従来どおり断る
    func testRefusesWhenTheQemuStaysAfterWaiting() async {
        let ps = "qemu-system-aarch64-headless -avd Pixel_9 -no-window\n"
        let refusal = await DeviceBooter.refusalAfterWaitingForExit(
            avdID: "Pixel_9", graceSeconds: 0.05, pollNanoseconds: 1_000_000, readPS: { ps })
        XCTAssertNotNil(refusal)
    }

    private final class LockedCounter: @unchecked Sendable {  // 単一テスト内の逐次呼び出し + ロックで保護
        private let lock = NSLock()
        private var n = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        func increment() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    }

    /// 起動待ちが尽きたら、自分が起こした子を止めてから throw する(止めずに throw すると呼び手の再試行が2つ目を起こす)
    func testTimedOutStartStopsItsOwnChildBeforeThrowing() throws {
        let booter = try source("Sources/FTAndroid/DeviceBooter.swift")
        XCTAssertTrue(booter.contains("let stopped = await stopOwnChild(process)"))
        XCTAssertFalse(booter.contains("        process.terminate()\n        throw DeviceBooterError.commandFailed("))
    }

    func testStopAndStartDoesNotStartWhileTheOldSerialIsStillListed() throws {
        let factory = try source("Sources/FTAndroid/ProfileWorkerFactory.swift")
        XCTAssertTrue(factory.contains("— not starting a second one"))
    }

    // MARK: - ④ ゲストの再起動の届き方

    func testAdbRebootTimeoutIsDeliveryUnknownNotNotDelivered() {
        XCTAssertEqual(ProfileWorkerFactory.guestRebootDelivery(adbStatus: nil, timedOut: true), .unknown)
        XCTAssertEqual(ProfileWorkerFactory.guestRebootDelivery(adbStatus: 0, timedOut: false), .delivered)
        XCTAssertEqual(ProfileWorkerFactory.guestRebootDelivery(adbStatus: 1, timedOut: false), .notDelivered)
        XCTAssertEqual(ProfileWorkerFactory.guestRebootDelivery(adbStatus: nil, timedOut: false), .notDelivered)
    }

    /// VM リセットを撃ってよいのは「届いていない」と確定したときだけ
    func testGuestResetIsGatedOnNotDelivered() throws {
        let factory = try source("Sources/FTAndroid/ProfileWorkerFactory.swift")
        XCTAssertTrue(factory.contains("guestRebootDelivery(adbStatus: adbStatus, timedOut: timedOut) == .notDelivered,\n           await !EmulatorControl.reset(serial: serial)"))
    }

    // MARK: - ③ 回復の戻り値

    func testRepairResultNeverReportsAStageThatWasNotFired() {
        // 撃っておらず戻らなかった: nil
        XCTAssertNil(DisplayFreezeWatch.emulatorRepairResult(guestRebootFired: false, emulatorRestarted: false, deviceGone: false))
        // ゲストの再起動は撃った(戻りは見ていない): 撃った段として返す
        XCTAssertEqual(DisplayFreezeWatch.emulatorRepairResult(guestRebootFired: true, emulatorRestarted: false, deviceGone: false), .deviceRestart)
        // 停止と起動が戻った
        XCTAssertEqual(DisplayFreezeWatch.emulatorRepairResult(guestRebootFired: false, emulatorRestarted: true, deviceGone: false), .deviceRestart)
        // デバイスが消えた: 再起動した、と言わない
        XCTAssertNil(DisplayFreezeWatch.emulatorRepairResult(guestRebootFired: true, emulatorRestarted: false, deviceGone: true))
    }

    func testRepairEmulatorUsesTheOutcomeAndThePureResult() throws {
        let watch = try source("Sources/FTAndroid/DisplayFreezeWatch.swift")
        XCTAssertTrue(watch.contains("rebootGuestOutcome("))
        XCTAssertGreaterThanOrEqual(watch.components(separatedBy: "emulatorRepairResult(").count - 1, 3)
    }
}
