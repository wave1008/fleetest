import XCTest
@testable import FTCore

/// pid 再利用・ログ回転・accept の待ち・ps の空白・test-and-set・flock 内の remove
final class OI382FixTests: XCTestCase {

    // ① 公表した時刻より後に起動した同じ pid(再利用)の記録は無視する
    func testFrozenStoreIgnoresReusedPid() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ft-oi382-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pid = ProcessInfo.processInfo.processIdentifier
        let started = try XCTUnwrap(ProcessLiveness.startTime(pid))
        // 自分より前に書かれた記録 = 今の pid は書き手ではなく再利用された別プロセス
        let before = started.addingTimeInterval(-3600)
        DeviceFrozenStore.publish(stateDir: dir, key: "k", verdict: FrozenVerdict([.uniformBlank]), pid: pid, now: before)
        XCTAssertNil(DeviceFrozenStore.current(stateDir: dir, key: "k", now: before))
        DeviceFrozenStore.publish(stateDir: dir, key: "k", verdict: FrozenVerdict([.uniformBlank]), pid: pid, now: Date())
        XCTAssertNotNil(DeviceFrozenStore.current(stateDir: dir, key: "k"))
    }

    // ② ログ回転・accept の待ち
    func testFMServeLogRotationThreshold() {
        XCTAssertFalse(FMServeHost.shouldRotateLog(size: FMServeHost.logRotationBytes))
        XCTAssertTrue(FMServeHost.shouldRotateLog(size: FMServeHost.logRotationBytes + 1))
    }

    func testAcceptBacksOffOnlyOnDescriptorExhaustion() {
        XCTAssertTrue(FramedUnixSocket.shouldBackOffAfterAcceptFailure(errno: EMFILE))
        XCTAssertTrue(FramedUnixSocket.shouldBackOffAfterAcceptFailure(errno: ENFILE))
        XCTAssertFalse(FramedUnixSocket.shouldBackOffAfterAcceptFailure(errno: ECONNABORTED))
        XCTAssertFalse(FramedUnixSocket.shouldBackOffAfterAcceptFailure(errno: EINTR))
    }

    // ③ パスに空白があっても壊れない
    func testLiveEncodeStreamsCountsProgramPathWithSpaces() {
        let ps = "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/fleetest/.build/fleetest-simstream --udid A --codec h264\n"
            + "/Users/me/fleetest-simstream --udid B --codec mjpeg\n"
            + "/bin/sh -c /x/fleetest-simstream --codec h264\n"
        XCTAssertEqual(LiveEncodeStreams.count(psOutput: ps), 1)
    }

    func testLocalStreamHolderParsesProgramPathWithSpaces() {
        let line = "  77  01:00:00 /Users/me/Mobile Documents/x/fleetest-simstream --udid U1 --codec h264 FT_STREAM_OWNER=w1"
        let rows = LocalStreamHolder.parse(psOutput: line)
        XCTAssertEqual(rows.count, 1)
        let holders = LocalStreamHolder.helpers(for: .iosSimulator(udid: "U1"), in: rows)
        XCTAssertEqual(holders.map(\.pid), [77])
        XCTAssertEqual(holders.first?.owner, "w1")
    }

    func testBridgeOwnershipReadsOwnerPathWithSpaces() throws {
        let command = "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test-without-building"
            + " -xctestrun /Users/me/Library/Mobile Documents/ft clone/.fleetest/DerivedData/Build/Products/FleetestRunner-8125.xctestrun"
            + " -destination platform=iOS Simulator,id=B422AB58-6C79-45BC-92F0-BEF88061C8E1"
        let runner = try XCTUnwrap(BridgeOwnership.runnerProcess(fromCommand: command))
        XCTAssertEqual(runner.ownerRepo, "/Users/me/Library/Mobile Documents/ft clone")
        XCTAssertEqual(runner.port, 8125)
    }

    // ⑤ 同時 stop の判定は test-and-set(1つだけが false を受ける)
    func testStopGateTestAndSetAdmitsExactlyOne() {
        let gate = StopGate()
        XCTAssertFalse(gate.testAndSet())
        XCTAssertTrue(gate.testAndSet())
        XCTAssertTrue(gate.isSet)
    }

    // ⑤ remove は flock の内側: ロックを握っている間は終わらない
    func testJobRemoveWaitsForTheLock() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ft-oi382-job-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = JobProgressLedger.begin(title: "t", ownerPid: ProcessInfo.processInfo.processIdentifier,
                                             runs: [], issuer: nil, directory: dir)
        let lockPath = dir.appendingPathComponent("\(record.jobID).lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            JobProgressLedger.remove(jobID: record.jobID, directory: dir)
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 0.5), .timedOut)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(record.jobID).json").path))
        flock(fd, LOCK_UN); close(fd)
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(record.jobID).json").path))
    }
}
