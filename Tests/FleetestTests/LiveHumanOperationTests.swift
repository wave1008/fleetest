import XCTest
import FTBridgeClient
import FTCore
@testable import fleetest

/// run 中の人のライブ操作を台帳へ残す純粋な部分(label・書く条件)と serve の配線
final class LiveHumanOperationTests: XCTestCase {
    private func label(_ raw: [String: Any]) -> String? {
        let cmd = raw["cmd"] as? String ?? ""
        return LiveHumanOperation.label(for: ApiLiveServeCommand(cmd: cmd, raw: raw))
    }

    func testCoordinateLabels() {
        XCTAssertEqual(label(["cmd": "tap", "x": 120.4, "y": 340.6]), "tap (120, 341)")
        XCTAssertEqual(label(["cmd": "doubleTap", "x": 1, "y": 2]), "double tap (1, 2)")
        XCTAssertEqual(label(["cmd": "press", "x": 5, "y": 6, "duration": 0.8]), "long press (5, 6) 0.8s")
        XCTAssertEqual(label(["cmd": "drag", "fromX": 1, "fromY": 2, "toX": 3, "toY": 4]), "drag (1, 2) → (3, 4)")
        XCTAssertEqual(label(["cmd": "pinch", "scale": 1.5]), "pinch ×1.5")
    }

    func testSimpleLabels() {
        XCTAssertEqual(label(["cmd": "home"]), "home")
        XCTAssertEqual(label(["cmd": "appSwitcher"]), "app switcher")
        XCTAssertEqual(label(["cmd": "fold", "state": "fold"]), "fold")
        XCTAssertEqual(label(["cmd": "fold", "state": "unfold"]), "unfold")
    }

    /// 入力した文字列(OTP・パスワード)は label のどこにも入らない
    func testTypeKeepsOnlyTheCharacterCount() throws {
        let typed = try XCTUnwrap(label(["cmd": "type", "text": "s3cret-OTP"]))
        XCTAssertEqual(typed, "type (10 characters)")
        XCTAssertFalse(typed.contains("s3cret"))
        XCTAssertEqual(label(["cmd": "type", "text": "x"]), "type (1 character)")
    }

    func testObservationCommandsAndUnknownOnesAreNotRecorded() {
        XCTAssertNil(label(["cmd": "refresh"]))
        XCTAssertNil(label(["cmd": "no-such-command"]))
    }

    func testGestureLabelCountsFingers() {
        let finger: [String: Any] = ["points": [["x": 1, "y": 2, "t": 0], ["x": 3, "y": 4, "t": 0.1]]]
        XCTAssertEqual(label(["cmd": "gesture", "fingers": [finger, finger]]), "gesture (2 fingers)")
    }

    /// run が使用中(自分以外の生きた持ち主)のときだけ書く
    func testShouldRecordOnlyWhileAnotherProcessHoldsTheRunLease() {
        XCTAssertFalse(LiveHumanOperation.shouldRecord(runHolderPID: nil, ownPID: 10))
        XCTAssertTrue(LiveHumanOperation.shouldRecord(runHolderPID: 11, ownPID: 10))
        XCTAssertFalse(LiveHumanOperation.shouldRecord(runHolderPID: 10, ownPID: 10))
    }

    /// 実際の run-lease(launchd の pid は必ず生きている)を立てた/立てないときの serve 側の判定と書き込み
    func testLeaseRecordsOnlyWhileRunLeaseIsFresh() throws {
        let stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-live-human-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let lease = LiveDeviceLease(stateDir: stateDir, key: "UDID-RUN", pid: ProcessInfo.processInfo.processIdentifier,
                                    log: { _ in })
        XCTAssertFalse(lease.runIsUsingDevice(), "run-lease が無い = 普段のライブ操作")
        RunLease.write(stateDir: stateDir, key: "UDID-RUN", pid: 1)
        XCTAssertTrue(lease.runIsUsingDevice())
        let at = Date()
        lease.recordHumanOperation(label: "home", ok: true, at: at)
        let rows = HumanOperationLedger.entries(stateDir: stateDir, key: "UDID-RUN",
                                                from: at.addingTimeInterval(-1), to: at.addingTimeInterval(1))
        XCTAssertEqual(rows.map(\.label), ["home"])
    }

    // MARK: - 配線

    private func serveSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/ApiLiveCommand.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// handle は操作を撃つ前に label を作り、成功と失敗の両方で書く。書く条件は run の使用中
    func testHandleRecordsBothOutcomesGatedOnRunUsage() throws {
        let code = try serveSource()
        XCTAssertTrue(code.contains("deviceLease?.runIsUsingDevice() == true"))
        XCTAssertTrue(code.contains("command.drivesDevice && deviceLease?.runIsUsingDevice()"))
        XCTAssertTrue(code.contains("recordHumanOperation(label: humanLabel, ok: true, at: operatedAt)"))
        XCTAssertTrue(code.contains("recordHumanOperation(label: humanLabel, ok: false, at: operatedAt)"))
        let labelAt = try XCTUnwrap(code.range(of: "LiveHumanOperation.label(for: command"))
        let performAt = try XCTUnwrap(code.range(of: "try await perform(command: command"))
        XCTAssertLessThan(labelAt.lowerBound, performAt.lowerBound, "label は操作の前に作る")
    }
}
