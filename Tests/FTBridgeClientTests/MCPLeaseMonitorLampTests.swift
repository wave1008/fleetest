// モニターの実行中のランプ(inMCP)は MCP の呼び出しの進行中だけ点く(lease は呼び出しの外でも残るので使わない)。ライブ操作の印はモニターでデバイスを選ぶだけで立つので数えない

import XCTest
@testable import FTBridgeClient
import FTCore

final class MCPLeaseMonitorLampTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private let pid = ProcessInfo.processInfo.processIdentifier

    func testLampLightsOnlyWhileACallIsInProgress() {
        let dir = tempDir()
        MCPDeviceLease.write(stateDir: dir, key: "UDID-A", pid: pid, role: .mcp)
        XCTAssertFalse(MCPDeviceLease.isCallInProgress(stateDir: dir, key: "UDID-A", excluding: []),
                       "lease だけ(呼び出しの外)では点かない")
        MCPDeviceLease.beginCall(stateDir: dir, key: "UDID-A", pid: pid)
        XCTAssertTrue(MCPDeviceLease.isCallInProgress(stateDir: dir, key: "UDID-A", excluding: []))
        XCTAssertFalse(MCPDeviceLease.isCallInProgress(stateDir: dir, key: "UDID-B", excluding: []), "別の鍵では点かない")
        XCTAssertFalse(MCPDeviceLease.isCallInProgress(stateDir: dir, key: "UDID-A", excluding: [pid]),
                       "モニター自身・拡張の pid は除く")
        MCPDeviceLease.endCall(stateDir: dir, pid: pid)
        XCTAssertFalse(MCPDeviceLease.isCallInProgress(stateDir: dir, key: "UDID-A", excluding: []))
        XCTAssertNotNil(MCPDeviceLease.holderPID(stateDir: dir, key: "UDID-A", excluding: []), "lease は残る")
    }

    func testStaleActiveMarkDoesNotLight() throws {
        let dir = tempDir()
        MCPDeviceLease.beginCall(stateDir: dir, key: "UDID-A", pid: pid)
        let url = MCPDeviceLease.activeURL(stateDir: dir, key: "UDID-A", pid: pid)
        // 開始時刻が合わない = pid が再利用された別プロセス
        try "\(pid) 1".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertFalse(MCPDeviceLease.isCallInProgress(stateDir: dir, key: "UDID-A", excluding: []))
    }

    func testSweepRemovesOnlyDeadActiveMarks() throws {
        let dir = tempDir()
        MCPDeviceLease.beginCall(stateDir: dir, key: "UDID-A", pid: pid)
        let live = MCPDeviceLease.activeURL(stateDir: dir, key: "UDID-A", pid: pid)
        let dead = MCPDeviceLease.activeURL(stateDir: dir, key: "UDID-B", pid: pid)
        try "\(pid) 1".write(to: dead, atomically: true, encoding: .utf8)
        MCPDeviceLease.sweepDeadActiveMarks(stateDir: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path))
    }

    func testActiveMarkIsNotALeaseFile() {
        let dir = tempDir()
        MCPDeviceLease.beginCall(stateDir: dir, key: "UDID-A", pid: pid)
        XCTAssertFalse(MCPDeviceLease.isLeaseFile(MCPDeviceLease.activeURL(stateDir: dir, key: "UDID-A", pid: pid).lastPathComponent))
        XCTAssertNil(MCPDeviceLease.holderPID(stateDir: dir, key: "UDID-A", excluding: []), "使用中には数えない")
    }

    func testLiveControlLeaseDoesNotLightTheLamp() {
        let dir = tempDir()
        MCPDeviceLease.write(stateDir: dir, key: "UDID-A", pid: pid, role: .live(lastAction: Date()))
        XCTAssertFalse(MCPDeviceLease.isCallInProgress(stateDir: dir, key: "UDID-A", excluding: []))
        XCTAssertNotNil(MCPDeviceLease.holderPID(stateDir: dir, key: "UDID-A", excluding: []),
                        "使用中(inSession)としては数える = 判定の軸が別")
    }

    func testRemoveAllClearsActiveMarks() {
        let dir = tempDir()
        MCPDeviceLease.beginCall(stateDir: dir, key: "UDID-A", pid: pid)
        MCPDeviceLease.removeAll(stateDir: dir, pid: pid)
        XCTAssertFalse(MCPDeviceLease.isCallInProgress(stateDir: dir, key: "UDID-A", excluding: []))
    }
}
