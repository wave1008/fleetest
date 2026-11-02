// crashAnnotated が .ips 無しのとき、殺された可能性だけを言わず生死を確かめる根拠になる純粋関数。
// 実測 2026-09-17: SIGSTOP でアプリを止めても .ips は出ず、プロセスは生きたまま無応答だった。

import XCTest
@testable import FTBridgeClient

final class SimulatorAppProcessTests: XCTestCase {

    func testRunningAppIsDetected() {
        let output = "12345\t0\tUIKitApplication:com.example.app[0x1234][rb-legacy]\n"
        XCTAssertTrue(SimulatorAppProcess.processIsRunning(inLaunchctlListOutput: output, bundleID: "com.example.app"))
    }

    /// PID 列が "-" は未起動を表す(生きているとは言わない)
    func testNotRunningAppShowsDashPID() {
        let output = "-\t0\tUIKitApplication:com.example.app[0x1234][rb-legacy]\n"
        XCTAssertFalse(SimulatorAppProcess.processIsRunning(inLaunchctlListOutput: output, bundleID: "com.example.app"))
    }

    func testBundleIDNotPresentAtAll() {
        let output = "12345\t0\tUIKitApplication:com.other.app[0x1234][rb-legacy]\n"
        XCTAssertFalse(SimulatorAppProcess.processIsRunning(inLaunchctlListOutput: output, bundleID: "com.example.app"))
    }

    /// ラベルの前方一致で別 bundle ID を拾わない("com.example.app2" は "com.example.app" とは別物)
    func testDoesNotPrefixMatchOtherBundleIDs() {
        let output = "12345\t0\tUIKitApplication:com.example.app2[0x1234][rb-legacy]\n"
        XCTAssertFalse(SimulatorAppProcess.processIsRunning(inLaunchctlListOutput: output, bundleID: "com.example.app"))
    }

    func testEmptyOutput() {
        XCTAssertFalse(SimulatorAppProcess.processIsRunning(inLaunchctlListOutput: "", bundleID: "com.example.app"))
    }

    /// 記録済みでも新しく見つけても同じ形(読み手が経路で読み分けなくてよい)
    func testCrashReportLineFormat() {
        XCTAssertEqual(SimulatorAppProcess.crashReportLine(path: "/x/A.ips", reason: "EXC_CRASH SIGABRT"),
                       "crash report: /x/A.ips (EXC_CRASH SIGABRT)")
        XCTAssertEqual(SimulatorAppProcess.crashReportLine(path: "/x/A.ips", reason: nil), "crash report: /x/A.ips")
    }

    // MARK: - ホストのプロセスで生存を確かめる速い経路

    func testAppBundleDirectoryIsTheAppOfTheExecutableUnderThisDevice() {
        let marker = SimulatorAppProcess.appContainerMarker(udid: "U1")
        let base = "/Users/x/Library/Developer/CoreSimulator/Devices/U1/data/Containers/Bundle/Application/G/"
        XCTAssertEqual(SimulatorAppProcess.appBundleDirectory(ofExecutable: base + "A.app/A", marker: marker), base + "A.app")
        // 拡張は自分の bundle ID を持つ = 本体と取り違えない
        XCTAssertNil(SimulatorAppProcess.appBundleDirectory(ofExecutable: base + "A.app/PlugIns/W.appex/W", marker: marker))
        // 別のデバイスの同じアプリを拾わない
        XCTAssertNil(SimulatorAppProcess.appBundleDirectory(
            ofExecutable: "/Users/x/Library/Developer/CoreSimulator/Devices/U2/data/Containers/Bundle/Application/G/A.app/A",
            marker: marker))
    }

    /// 置き場の下の `.app` の実行ファイルを本当に起こし、プロセス表から見つかる・止めたら見つからないことを確かめる
    /// (Simulator の代わりに同じ形のパスへ署名し直した sleep を置く)
    func testRunningProcessUnderTheDeviceContainerIsFound() throws {
        let udid = "FAKE-" + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent(
            "CoreSimulator/Devices/\(udid)/data/Containers/Bundle/Application/G1/Fake.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let executable = app.appendingPathComponent("Fake")
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: executable.path)
        // 複製した OS の実行ファイルは署名し直さないと起動時に殺される
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["-f", "-s", "-", executable.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run(); sign.waitUntilExit()
        try XCTUnwrap(sign.terminationStatus == 0 ? true : nil, "codesign に失敗")
        (["CFBundleIdentifier": "com.example.fake"] as NSDictionary).write(
            to: app.appendingPathComponent("Info.plist"), atomically: true)

        let process = Process()
        process.executableURL = executable
        process.arguments = ["30"]
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        XCTAssertTrue(SimulatorAppProcess.hostProcessFound(udid: udid, bundleID: "com.example.fake"))
        XCTAssertFalse(SimulatorAppProcess.hostProcessFound(udid: udid, bundleID: "com.example.other"))
        process.terminate(); process.waitUntilExit()
        XCTAssertFalse(SimulatorAppProcess.hostProcessFound(udid: udid, bundleID: "com.example.fake"))
    }
}

