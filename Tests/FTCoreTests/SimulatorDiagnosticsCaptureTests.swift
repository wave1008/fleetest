import XCTest
@testable import FTCore

final class SimulatorDiagnosticsCaptureTests: XCTestCase {
    private var root: URL!
    private let udid = "ABCDEF12-3456-7890-ABCD-EF1234567890"

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sim-diag-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        SimulatorDiagnosticsCapture.resetForTesting()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func run(reason: String = "display-not-applied", commands: @escaping SimulatorDiagnosticsCapture.CommandRunner,
                     reports: URL? = nil) -> (url: URL?, text: String) {
        let done = expectation(description: "log section written")
        let url = SimulatorDiagnosticsCapture.capture(
            udid: udid, reason: reason, directory: root, reportsDirectory: reports ?? root.appendingPathComponent("none"),
            commands: commands, completion: { done.fulfill() })
        if url != nil { wait(for: [done], timeout: 10) }
        return (url, url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
    }

    func testCommandShapes() {
        XCTAssertEqual(SimulatorDiagnosticsCapture.launchctlCommand(udid: udid),
                       ["xcrun", "simctl", "spawn", udid, "launchctl", "list"])
        let log = SimulatorDiagnosticsCapture.logShowCommand(udid: udid)
        XCTAssertEqual(Array(log.prefix(8)), ["xcrun", "simctl", "spawn", udid, "log", "show", "--last", "10m"])
        XCTAssertTrue(log.contains("--style") && log.contains("compact"))
        XCTAssertEqual(log.last, SimulatorDiagnosticsCapture.logPredicate)
        XCTAssertTrue(SimulatorDiagnosticsCapture.logPredicate.contains("SpringBoard"))
        XCTAssertTrue(SimulatorDiagnosticsCapture.logPredicate.contains("UIUserInterfaceStyle"))
        XCTAssertTrue(SimulatorDiagnosticsCapture.logPredicate.contains("category == \"UserInterfaceStyleArbiter\""))
        XCTAssertTrue(SimulatorDiagnosticsCapture.logPredicate.hasSuffix("AND NOT (subsystem == \"com.apple.dt.xctest\")"),
                      "XCUITest の行を除かないと末尾の行数が SpringBoard の木の読みで埋まる")
    }

    /// 外観の部品の行は長い窓(24h)で読み、全行を書く。0 行も書く(起動から1度も動いていない、という事実)
    func testArbiterSectionReadsTheLongWindowAndKeepsEveryLine() {
        let command = SimulatorDiagnosticsCapture.arbiterLogCommand(udid: udid)
        XCTAssertEqual(Array(command.prefix(8)), ["xcrun", "simctl", "spawn", udid, "log", "show", "--last", "24h"])
        XCTAssertEqual(command.last, SimulatorDiagnosticsCapture.arbiterPredicate)
        let arbiterLine = "2026-11-25 17:55:47.579 Df SpringBoard[6624:b8d0] [com.apple.UIKit:UserInterfaceStyleArbiter] Arbiter _updateCurrentStyleAndNotify:1 forReason:0"
        let result = run { args, _ in
            if args.contains("launchctl") { return Shell.Result(status: 0, output: "1\t0\tcom.apple.SpringBoard\n") }
            if args.contains("24h") { return Shell.Result(status: 0, output: "Timestamp Ty Process\n" + arbiterLine + "\n") }
            return Shell.Result(status: 0, output: "line1\n")
        }
        XCTAssertTrue(result.text.contains("== appearance arbiter (SpringBoard UserInterfaceStyleArbiter, last 24h) =="))
        XCTAssertTrue(result.text.contains("1 line(s)\n" + arbiterLine), "見出しの行を数えず、部品の行だけを全部書く")
        let empty = SimulatorDiagnosticsCapture.arbiterSection(command: command) { _, _ in Shell.Result(status: 0, output: "Timestamp\n") }
        XCTAssertTrue(empty.contains("0 line(s)"))
    }

    func testFilterLaunchctlKeepsOnlyRelevantLabels() {
        let output = "PID\tStatus\tLabel\n123\t0\tcom.apple.SpringBoard\n-\t-5\tcom.apple.backboardd\n9\t0\tcom.apple.mobilesafari\n"
        XCTAssertEqual(SimulatorDiagnosticsCapture.filterLaunchctl(output),
                       ["123\t0\tcom.apple.SpringBoard", "-\t-5\tcom.apple.backboardd"])
    }

    func testWritesLaunchctlAndLogSections() {
        let result = run { args, _ in
            args.contains("launchctl") ? Shell.Result(status: 0, output: "-\t-5\tcom.apple.SpringBoard\n")
                : Shell.Result(status: 0, output: "line1\nline2\n")
        }
        XCTAssertEqual(result.url?.deletingLastPathComponent().lastPathComponent, "diagnostics")
        XCTAssertTrue(result.url?.lastPathComponent.hasPrefix("ABCDEF12-") == true)
        XCTAssertTrue(result.url?.lastPathComponent.hasSuffix("-display-not-applied.txt") == true)
        XCTAssertTrue(result.text.contains("-\t-5\tcom.apple.SpringBoard"))
        XCTAssertTrue(result.text.contains("line2"))
        XCTAssertTrue(result.text.contains("showing the last 2 of 2 lines"))  // 末尾の改行を1行に数えない
        XCTAssertFalse(result.text.contains("log not captured"))
    }

    func testNonZeroExitIsRecordedAsNotCaptured() {
        let result = run { _, _ in Shell.Result(status: 3, output: "boom") }
        XCTAssertTrue(result.text.contains("not captured: launchctl exited with status 3"))
        XCTAssertTrue(result.text.contains("not captured: log show exited with status 3"))
    }

    func testTimeoutIsRecordedAsNotCaptured() {
        let result = run { _, _ in throw ShellError.timedOut(args: ["x"], seconds: 5) }
        XCTAssertTrue(result.text.contains("not captured: simctl did not finish within"))
    }

    func testPlaceholderStaysWhileLogIsPending() {
        let gate = DispatchSemaphore(value: 0)
        let url = SimulatorDiagnosticsCapture.capture(
            udid: udid, reason: "pending", directory: root, reportsDirectory: root.appendingPathComponent("none"),
            commands: { args, _ in
                if args.contains("log") { _ = gate.wait(timeout: .now() + 10) }
                return Shell.Result(status: 0, output: "x\n")
            })
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        XCTAssertTrue(text.contains("log not captured yet"))
        gate.signal()
    }

    /// 本物の ~/Library/Logs/DiagnosticReports を読まない(共有資源。CLAUDE.md の SharedResource の規律)
    private var noReports: URL { root.appendingPathComponent("none") }

    func testSameReasonIsCapturedOnlyOncePerDirectoryAndUdid() {
        XCTAssertNotNil(run { _, _ in Shell.Result(status: 0, output: "") }.url)
        XCTAssertNil(SimulatorDiagnosticsCapture.capture(
            udid: udid, reason: "display-not-applied", directory: root, reportsDirectory: noReports, commands: { _, _ in Shell.Result(status: 0, output: "") }))
        XCTAssertNotNil(run(reason: "worker-revive") { _, _ in Shell.Result(status: 0, output: "") }.url)
    }

    func testSameReasonIsCapturedAgainOnceTheLookbackWindowHasPassed() {
        let t0 = Date()
        let ok: SimulatorDiagnosticsCapture.CommandRunner = { _, _ in Shell.Result(status: 0, output: "") }
        XCTAssertNotNil(SimulatorDiagnosticsCapture.capture(udid: udid, reason: "bridge-startup-timeout", directory: root, now: t0,
                                                            reportsDirectory: noReports, commands: ok))
        let window = TimeInterval(SimulatorDiagnosticsCapture.logLookbackMinutes * 60)
        XCTAssertNil(SimulatorDiagnosticsCapture.capture(udid: udid, reason: "bridge-startup-timeout", directory: root,
                                                         now: t0.addingTimeInterval(window - 1),
                                                         reportsDirectory: noReports, commands: ok))
        XCTAssertNotNil(SimulatorDiagnosticsCapture.capture(udid: udid, reason: "bridge-startup-timeout", directory: root,
                                                            now: t0.addingTimeInterval(window + 1),
                                                            reportsDirectory: noReports, commands: ok))
    }

    func testDefaultsArePinned() {
        XCTAssertEqual(SimulatorDiagnosticsCapture.launchctlTimeoutSeconds, 5)
        XCTAssertEqual(SimulatorDiagnosticsCapture.logLookbackMinutes, 10)  // 重複抑止の窓も兼ねる
        XCTAssertEqual(SimulatorDiagnosticsCapture.logShowTimeoutSeconds, 90)
        XCTAssertEqual(SimulatorDiagnosticsCapture.logTailLines, 800)
        XCTAssertEqual(SimulatorDiagnosticsCapture.reportWindowSeconds, 3600)
        XCTAssertEqual(SimulatorDiagnosticsCapture.reportListLimit, 20)
        XCTAssertEqual(SimulatorDiagnosticsCapture.exitWaitSeconds, 10)
    }

    func testOffPoolCaptureReturnsAfterItsOwnLogIsWritten() async throws {
        let captured = await SimulatorDiagnosticsCapture.captureOffCooperativePool(
            udid: udid, reason: "wait", fallbackDirectory: nil, directory: root, reportsDirectory: noReports,
            commands: { args, _ in
                if args.contains("show") { Thread.sleep(forTimeInterval: 0.3) }  // 背景の log show が遅い回
                return Shell.Result(status: 0, output: "LOGLINE\n")
            })
        // 戻った時点で統合ログが書き終わっている(呼び手のプロセスがすぐ終わっても仮の行のまま残らない)
        let text = try String(contentsOf: try XCTUnwrap(captured.url), encoding: .utf8)
        XCTAssertTrue(text.contains("LOGLINE"))
        XCTAssertFalse(text.contains("log not captured yet"))
    }

    func testFileNameTimeIsUTC() {
        // 2026-11-25T00:00:00Z
        XCTAssertEqual(SimulatorDiagnosticsCapture.timestamp(Date(timeIntervalSince1970: 1_795_564_800)), "20261125T000000Z")
    }

    func testDirectoryKeepsOnlyTheNewestFiles() throws {
        XCTAssertEqual(SimulatorDiagnosticsCapture.maxFilesPerDirectory, 50)
        let dir = root.appendingPathComponent("prune")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date()
        for i in 0..<5 {
            let path = dir.appendingPathComponent("f\(i).txt").path
            FileManager.default.createFile(atPath: path, contents: Data())
            // f0・f1 は書き直しがありうる窓(logShowTimeoutSeconds)より古い。f2〜f4 は窓の中 = 上限の外でも消さない
            let age: Double = i < 2 ? 1000 + Double(i) : Double(i)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: path)
        }
        SimulatorDiagnosticsCapture.pruneOldest(in: dir, keep: 1, now: now)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(left, ["f2.txt", "f3.txt", "f4.txt"])  // 上限 1 でも窓の中の3つは残し、古い f0・f1 だけ消す
    }

    func testReportsListsOnlyRecentSpringBoardAndBackboarddFiles() throws {
        let reports = root.appendingPathComponent("reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        let now = Date()
        func make(_ name: String, age: TimeInterval) throws {
            let path = reports.appendingPathComponent(name).path
            FileManager.default.createFile(atPath: path, contents: Data())
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: path)
        }
        try make("SpringBoard-2026.ips", age: 60)
        try make("backboardd-2026.ips", age: 120)
        try make("SpringBoard-old.ips", age: 7200)
        try make("Safari-2026.ips", age: 60)
        let section = SimulatorDiagnosticsCapture.reportsSection(directory: reports, now: now)
        XCTAssertTrue(section.contains("SpringBoard-2026.ips") && section.contains("backboardd-2026.ips"))
        XCTAssertFalse(section.contains("SpringBoard-old.ips") || section.contains("Safari"))
    }
}
