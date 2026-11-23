// align / setup のロック取得も待機列を通す(RR-18.9「待たない取得も列を通す」)。直接 mkdir すると先頭で待っている run を
// 追い越し、その run が照合した版のランナーを開始前に差し替える

import Foundation
import XCTest
import FTRemote

final class AlignDispatchQueueTests: XCTestCase {
    private let holder = RemoteDispatchLockInfo(issuerHost: "PC1", pid: 42, acquiredAt: "2026-11-23T00:00:00Z", issuer: "alice")

    func testAcquiredIsNotRefused() {
        XCTAssertNil(RemoteDispatchLock.alignRefusal(.acquired))
    }

    func testHeldLockIsRefusedWithTheHolder() {
        XCTAssertEqual(RemoteDispatchLock.alignRefusal(.held(position: 1, total: 1, holder: holder)),
                       RemoteDispatchLock.alignHeldMessage(holder))
    }

    /// ロックが空いていても、前に待っている run が居れば追い越さない
    func testQueuedRunsAheadAreNotOvertaken() throws {
        let message = try XCTUnwrap(RemoteDispatchLock.alignRefusal(.waiting(position: 3, total: 3, holder: nil)))
        XCTAssertTrue(message.hasPrefix("2 dispatch(es) are waiting"), message)
        XCTAssertFalse(message.contains("the lock is held"), message)
    }

    /// ロックを直接取る(列を通らない)のは待機列そのものと、奪う口(`--force-lock`)だけ
    func testOnlyTheQueueTakesTheLockDirectly() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        var callers: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("RemoteDispatchLock.acquireCommand(") { callers.append(file.lastPathComponent) }
        }
        XCTAssertEqual(callers.sorted(), ["RemoteDispatchQueue.swift"], "待機列を通らずにロックを取っている")
    }
}
