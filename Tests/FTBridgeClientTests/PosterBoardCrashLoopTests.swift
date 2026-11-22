// PosterBoard の落ち続けの判定(純粋関数)と .ips の読み(一時ディレクトリに実物の形を置く)。
// 読みの対象は引数のディレクトリだけ(ホストの DiagnosticReports には触れない = SharedResource は不要)。

import XCTest
@testable import FTBridgeClient

final class PosterBoardCrashLoopTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let udidA = "A4A2013B-768C-4D0B-911B-304BCDF2BA78"
    private let udidB = "B4A2013B-768C-4D0B-911B-304BCDF2BA78"

    private func crashes(_ udid: String, count: Int, secondsAgo: TimeInterval = 10) -> [PosterBoardCrashRecord] {
        (0..<count).map { PosterBoardCrashRecord(udid: udid, time: now.addingTimeInterval(-secondsAgo - Double($0))) }
    }

    func testDefaultsArePinned() {
        XCTAssertEqual(PosterBoardCrashLoop.windowSeconds, 1800)
        XCTAssertEqual(PosterBoardCrashLoop.threshold, 10)
    }

    func testFourCrashesDoNotMatchAndTenDo() {
        XCTAssertEqual(PosterBoardCrashLoop.looping(crashes: crashes(udidA, count: 4), now: now), [])
        XCTAssertEqual(PosterBoardCrashLoop.looping(crashes: crashes(udidA, count: 9), now: now), [])
        XCTAssertEqual(PosterBoardCrashLoop.looping(crashes: crashes(udidA, count: 10), now: now),
                       [.init(udid: udidA, count: 10)])
    }

    func testCrashesOutsideTheWindowAreNotCounted() {
        let old = crashes(udidA, count: 20, secondsAgo: PosterBoardCrashLoop.windowSeconds + 1)
        XCTAssertEqual(PosterBoardCrashLoop.looping(crashes: old, now: now), [])
        let mixed = crashes(udidA, count: 9) + crashes(udidA, count: 5, secondsAgo: PosterBoardCrashLoop.windowSeconds + 100)
        XCTAssertEqual(PosterBoardCrashLoop.looping(crashes: mixed, now: now), [])
    }

    func testCountsPerUDID() {
        let both = crashes(udidA, count: 6) + crashes(udidB, count: 6)
        XCTAssertEqual(PosterBoardCrashLoop.looping(crashes: both, now: now), [])
        let one = crashes(udidA, count: 12) + crashes(udidB, count: 3)
        XCTAssertEqual(PosterBoardCrashLoop.looping(crashes: one, now: now), [.init(udid: udidA, count: 12)])
    }

    // MARK: 読み

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PosterBoardCrashLoopTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = PosterBoardCrashLoop.timestampFormat
        return f.string(from: date)
    }

    private func write(_ name: String, header: String? = nil, body: String, crashedAt: Date, mtime: Date? = nil) throws {
        let head = header ?? #"{"app_name":"PosterBoard","timestamp":"\#(format(crashedAt))","bug_type":"309"}"#
        let url = dir.appendingPathComponent(name)
        try (head + "\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime ?? crashedAt], ofItemAtPath: url.path)
    }

    private func body(_ udid: String) -> String {
        #"{"coalitionName":"com.apple.CoreSimulator.SimDevice.\#(udid)","exception":{"type":"EXC_BREAKPOINT"}}"#
    }

    func testReadsRealShapedReportsAndSkipsTheRest() throws {
        let t = now.addingTimeInterval(-30)
        try write("PosterBoard-2026-11-22-104157.ips", body: body(udidA), crashedAt: t)
        // 別のアプリの記録・窓の外の mtime・壊れた本体・coalition が Simulator でないもの
        try write("SpringBoard-2026-11-22-104157.ips", body: body(udidA), crashedAt: t)
        try write("PosterBoard-old.ips", body: body(udidA), crashedAt: t, mtime: now.addingTimeInterval(-3600))
        try write("PosterBoard-broken.ips", body: "not json", crashedAt: t)
        try write("PosterBoard-host.ips", body: #"{"coalitionName":"com.apple.something"}"#, crashedAt: t)
        try write("PosterBoard-nohdr.ips", header: "garbage", body: body(udidA), crashedAt: t)
        let records = PosterBoardCrashLoop.readCrashes(directory: dir, now: now)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.udid, udidA)
        XCTAssertEqual(try XCTUnwrap(records.first).time.timeIntervalSince(t), 0, accuracy: 1)
    }

    /// 記録は書かれて間もなく `Retired/` へ移される(11/22 は当日の 69 件中 23 件)。直下だけ読むと壊れた台を当てられない
    func testReadsRetiredReportsToo() throws {
        let retired = dir.appendingPathComponent("Retired", isDirectory: true)
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        try write("PosterBoard-top.ips", body: body(udidA), crashedAt: now.addingTimeInterval(-60))
        try write("Retired/PosterBoard-moved.ips", body: body(udidA), crashedAt: now.addingTimeInterval(-120))
        XCTAssertEqual(PosterBoardCrashLoop.readCrashes(directory: dir, now: now).count, 2)
    }

    func testMissingDirectoryReadsAsEmpty() {
        XCTAssertEqual(PosterBoardCrashLoop.readCrashes(directory: dir.appendingPathComponent("none"), now: now), [])
    }

    func testReadCrashesFeedLooping() throws {
        for i in 0..<10 {
            try write("PosterBoard-\(i).ips", body: body(udidA), crashedAt: now.addingTimeInterval(-Double(i + 1)))
        }
        let found = PosterBoardCrashLoop.looping(crashes: PosterBoardCrashLoop.readCrashes(directory: dir, now: now), now: now)
        XCTAssertEqual(found.map(\.udid), [udidA])
    }
}
