// PosterBoard が落ち続けている Simulator を止める門: 使用中は止めず警告だけ・Booted でない台には撃たない。
// simctl・lease は差し替え口(偽)で通す。

import FTBridgeClient
import XCTest
@testable import FTAndroid

final class PosterBoardCrashLoopGuardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let udid = "A4A2013B-768C-4D0B-911B-304BCDF2BA78"

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _stopped: [String] = []
        private var _logs: [String] = []
        var stopped: [String] { lock.lock(); defer { lock.unlock() }; return _stopped }
        var logs: [String] { lock.lock(); defer { lock.unlock() }; return _logs }
        func stop(_ u: String) { lock.lock(); _stopped.append(u); lock.unlock() }
        func log(_ s: String) { lock.lock(); _logs.append(s); lock.unlock() }
    }

    private func crashes(count: Int) -> [PosterBoardCrashRecord] {
        (0..<count).map { PosterBoardCrashRecord(udid: udid, time: now.addingTimeInterval(-Double($0 + 1))) }
    }

    private func device(booted: Bool, transitioning: Bool = false) -> SimDeviceInfo {
        SimDeviceInfo(udid: udid, name: "iPhone 18 Pro-07", os: "iOS 27.2", booted: booted, transitioning: transitioning)
    }

    private func run(count: Int = 12, device: SimDeviceInfo?, refusal: String? = nil,
                     stopFails: Bool = false, recorder: Recorder) async -> [PosterBoardCrashLoopGuard.Report] {
        struct Failure: Error, LocalizedError { var errorDescription: String? { "boom\nsecond line" } }
        return await PosterBoardCrashLoopGuard.enforce(
            now: now, crashes: { self.crashes(count: count) },
            devices: { device.map { [$0] } ?? [] },
            refusal: { _, _ in refusal },
            stop: { d in
                recorder.stop(d.udid)
                if stopFails { throw Failure() }
            },
            log: { recorder.log($0) })
    }

    func testStopsABootedLoopingSimulatorAndExplainsErase() async throws {
        let r = Recorder()
        let reports = await run(device: device(booted: true), recorder: r)
        XCTAssertEqual(r.stopped, [udid])
        XCTAssertEqual(reports.first?.action, .stopped)
        XCTAssertEqual(reports.first?.count, 12)
        let line = try XCTUnwrap(r.logs.first)
        XCTAssertTrue(line.contains(udid) && line.contains("stopped the simulator") && line.contains("wipe-device"), line)
        XCTAssertTrue(line.contains("does not erase"), line)
    }

    func testInUseSimulatorIsNotStopped() async {
        let r = Recorder()
        let reports = await run(device: device(booted: true), refusal: "a run is using it", recorder: r)
        XCTAssertEqual(r.stopped, [])
        XCTAssertEqual(reports.first?.action, .skippedInUse("a run is using it"))
        XCTAssertTrue(r.logs.first?.contains("did not stop it") == true)
    }

    func testShutdownSimulatorIsLeftAloneAndSilent() async {
        let r = Recorder()
        let reports = await run(device: device(booted: false), recorder: r)
        XCTAssertEqual(r.stopped, [])
        XCTAssertEqual(reports, [])
        XCTAssertEqual(r.logs, [])
    }

    func testBelowThresholdDoesNothing() async {
        let r = Recorder()
        _ = await run(count: 4, device: device(booted: true), recorder: r)
        XCTAssertEqual(r.stopped, [])
        XCTAssertEqual(r.logs, [])
    }

    func testStopFailureIsReportedWithFirstLine() async {
        let r = Recorder()
        let reports = await run(device: device(booted: true), stopFails: true, recorder: r)
        XCTAssertEqual(reports.first?.action, .stopFailed("boom"))
    }
}
