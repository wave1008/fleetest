// PosterBoardCrashLoopSampler: 周期を待たせない・間隔の前は撃たない・使用中の警告は1回だけ。
// 配線: run の開始(run / api run の2経路)とモニターの周期が実際に呼んでいることをソース走査で固定する。

import FTAndroid
import XCTest

@testable import fleetest

final class PosterBoardCrashLoopSamplerTests: XCTestCase {
    private func report(_ action: PosterBoardCrashLoopGuard.Action, udid: String = "U1") -> PosterBoardCrashLoopGuard.Report {
        .init(name: "iPhone", udid: udid, count: 12, action: action)
    }

    func testIntervalIsPinned() {
        XCTAssertEqual(PosterBoardCrashLoopSampler.intervalSeconds, 120)
    }

    func testRunsOnceUntilTheIntervalPasses() async throws {
        let calls = LockedCounter()
        let clock = LockedClock(Date(timeIntervalSince1970: 1_000))
        let sampler = PosterBoardCrashLoopSampler(now: { clock.value }, enforce: { calls.increment(); return [] }, log: { _ in })
        sampler.scheduleIfDue()
        try await Task.sleep(nanoseconds: 300_000_000)
        sampler.scheduleIfDue()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(calls.value, 1)
        clock.value = Date(timeIntervalSince1970: 1_000 + PosterBoardCrashLoopSampler.intervalSeconds + 1)
        sampler.scheduleIfDue()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(calls.value, 2)
    }

    func testInUseWarningIsLoggedOncePerDeviceWhileItPersists() {
        let sampler = PosterBoardCrashLoopSampler(enforce: { [] }, log: { _ in })
        let inUse = report(.skippedInUse("a run is using it"))
        XCTAssertEqual(sampler.linesToLog([inUse]).count, 1)
        XCTAssertEqual(sampler.linesToLog([inUse]).count, 0)
        // 判定から外れたら忘れ、次に当たったらまた言う
        XCTAssertEqual(sampler.linesToLog([]).count, 0)
        XCTAssertEqual(sampler.linesToLog([inUse]).count, 1)
    }

    func testStoppedIsAlwaysLogged() {
        let sampler = PosterBoardCrashLoopSampler(enforce: { [] }, log: { _ in })
        XCTAssertEqual(sampler.linesToLog([report(.stopped)]).count, 1)
        XCTAssertEqual(sampler.linesToLog([report(.stopped)]).count, 1)
    }

    // MARK: 配線

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testRunStartAndMonitorCycleCallTheGuard() throws {
        XCTAssertTrue(try source("Sources/fleetest/ProfileRunner+Supply.swift").contains("PosterBoardCrashLoopGuard.enforce"),
                      "fleetest run の供給前の呼び出しが無い")
        XCTAssertTrue(try source("Sources/fleetest/ApiRunCommand.swift").contains("PosterBoardCrashLoopGuard.enforce"),
                      "fleetest api run の供給前の呼び出しが無い")
        let monitor = try source("Sources/fleetest/ApiMonitorCommand.swift")
        XCTAssertTrue(monitor.contains("PosterBoardCrashLoopSampler(") && monitor.contains("posterBoardCrashLoopSampler.scheduleIfDue()"),
                      "モニターの周期の呼び出しが無い")
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var value: Date {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
}
