import XCTest
@testable import FTCore

/// run 全体のロックの判定(RR-8.5)。待ち行列の順・共有と排他・複数キーの1つずつの取得・取り消しのすれ違い・接続の終わり・中断
final class RunLockTableTests: XCTestCase {
    private func owner(_ connection: Int, _ id: Int = 1) -> RunLockTable.Owner {
        RunLockTable.Owner(connection: connection, requestID: id)
    }

    func testExclusiveGrantsAtOnceWhenFreeAndQueuesTheNextInArrivalOrder() {
        var table = RunLockTable()
        XCTAssertEqual(table.acquire(connection: 1, requestID: 1, keys: ["a"], mode: .exclusive).grants, [owner(1)])
        XCTAssertEqual(table.acquire(connection: 2, requestID: 1, keys: ["a"], mode: .exclusive).grants, [])
        XCTAssertEqual(table.acquire(connection: 3, requestID: 1, keys: ["a"], mode: .exclusive).grants, [])
        XCTAssertEqual(table.release(connection: 1, requestID: 1).grants, [owner(2)])
        XCTAssertEqual(table.release(connection: 2, requestID: 1).grants, [owner(3)])
    }

    func testSharedHoldersCoexistButExclusiveWaitsForAll() {
        var table = RunLockTable()
        XCTAssertEqual(table.acquire(connection: 1, requestID: 1, keys: ["a"], mode: .shared).grants, [owner(1)])
        XCTAssertEqual(table.acquire(connection: 2, requestID: 1, keys: ["a"], mode: .shared).grants, [owner(2)])
        XCTAssertEqual(table.acquire(connection: 3, requestID: 1, keys: ["a"], mode: .exclusive).grants, [])
        XCTAssertEqual(table.release(connection: 1, requestID: 1).grants, [])
        XCTAssertEqual(table.release(connection: 2, requestID: 1).grants, [owner(3)])
    }

    func testNoNewSharedGrantWhileAnExclusiveWaiterIsQueued() {
        var table = RunLockTable()
        _ = table.acquire(connection: 1, requestID: 1, keys: ["a"], mode: .shared)
        _ = table.acquire(connection: 2, requestID: 1, keys: ["a"], mode: .exclusive)
        // 排他が待っているので、後から来た共有は渡さない(共有が続いて排他が飢えない)
        XCTAssertEqual(table.acquire(connection: 3, requestID: 1, keys: ["a"], mode: .shared).grants, [])
        XCTAssertEqual(table.release(connection: 1, requestID: 1).grants, [owner(2)])
        XCTAssertEqual(table.release(connection: 2, requestID: 1).grants, [owner(3)])
    }

    func testConsecutiveSharedWaitersAreGrantedTogetherWhenTheExclusiveReleases() {
        var table = RunLockTable()
        _ = table.acquire(connection: 1, requestID: 1, keys: ["a"], mode: .exclusive)
        _ = table.acquire(connection: 2, requestID: 1, keys: ["a"], mode: .shared)
        _ = table.acquire(connection: 3, requestID: 1, keys: ["a"], mode: .shared)
        XCTAssertEqual(Set(table.release(connection: 1, requestID: 1).grants), [owner(2), owner(3)])
    }

    func testMultiKeyRequestKeepsGrantedKeysWhileWaitingForTheNext() {
        var table = RunLockTable()
        _ = table.acquire(connection: 9, requestID: 1, keys: ["b"], mode: .exclusive)
        let effects = table.acquire(connection: 1, requestID: 1, keys: ["a", "b", "c"], mode: .exclusive)
        XCTAssertEqual(effects.grants, [])
        XCTAssertEqual(table.holders(of: "a"), [owner(1)], "a は取ったまま b を待つ")
        XCTAssertEqual(table.waitingKey(of: owner(1)), "b")
        // c は誰も持っていなくても、b が取れるまで取らない(1つずつ順に)
        XCTAssertEqual(table.holders(of: "c"), [])
        XCTAssertEqual(table.release(connection: 9, requestID: 1).grants, [owner(1)])
        XCTAssertEqual(table.holders(of: "c"), [owner(1)])
    }

    func testCancelOfAWaitingMultiKeyRequestReleasesTheKeysAlreadyGranted() {
        var table = RunLockTable()
        _ = table.acquire(connection: 9, requestID: 1, keys: ["b"], mode: .exclusive)
        _ = table.acquire(connection: 1, requestID: 1, keys: ["a", "b"], mode: .exclusive)
        _ = table.acquire(connection: 2, requestID: 1, keys: ["a"], mode: .exclusive)
        XCTAssertEqual(table.cancel(connection: 1, requestID: 1).grants, [owner(2)], "取っていた a が放されて次へ渡る")
        XCTAssertEqual(table.holders(of: "a"), [owner(2)])
        XCTAssertEqual(table.queue(of: "b"), [])
    }

    func testCancelAfterTheGrantIsTreatedAsReleaseSoTheCrossingNeverLeaksTheLock() {
        var table = RunLockTable()
        _ = table.acquire(connection: 1, requestID: 1, keys: ["a"], mode: .exclusive)
        _ = table.acquire(connection: 2, requestID: 1, keys: ["a"], mode: .exclusive)
        XCTAssertEqual(table.cancel(connection: 1, requestID: 1).grants, [owner(2)])
        XCTAssertFalse(table.isGranted(owner(1)))
    }

    func testRequestIDsAreIndependentSoALateGrantOfAnOldRequestIsNotAMixUpWithANewOne() {
        var table = RunLockTable()
        _ = table.acquire(connection: 9, requestID: 1, keys: ["a"], mode: .exclusive)
        _ = table.acquire(connection: 1, requestID: 1, keys: ["a"], mode: .exclusive)
        _ = table.cancel(connection: 1, requestID: 1)
        _ = table.acquire(connection: 1, requestID: 2, keys: ["a"], mode: .exclusive)
        XCTAssertEqual(table.release(connection: 9, requestID: 1).grants, [owner(1, 2)])
    }

    func testDuplicateRequestFails() {
        var table = RunLockTable()
        _ = table.acquire(connection: 1, requestID: 1, keys: ["a"], mode: .exclusive)
        let effects = table.acquire(connection: 1, requestID: 1, keys: ["b"], mode: .exclusive)
        XCTAssertEqual(effects.failures.map(\.owner), [owner(1)])
        XCTAssertEqual(table.holders(of: "b"), [])
    }

    func testConnectionClosedRemovesWaitersButKeepsGrantedRequestsForTheCallerToRelease() {
        var table = RunLockTable()
        _ = table.acquire(connection: 1, requestID: 1, keys: ["a"], mode: .exclusive)
        _ = table.acquire(connection: 3, requestID: 1, keys: ["c"], mode: .exclusive)
        _ = table.acquire(connection: 1, requestID: 2, keys: ["b", "c"], mode: .exclusive)
        _ = table.acquire(connection: 2, requestID: 1, keys: ["a"], mode: .exclusive)
        // 接続1 の要求2 は b を取って c が空いていないので待ち。要求1 は渡し済み
        let closed = table.connectionClosed(1)
        XCTAssertEqual(closed.held, [owner(1, 1)])
        XCTAssertEqual(table.holders(of: "b"), [], "待っていた要求の取った分は放す")
        XCTAssertEqual(table.holders(of: "a"), [owner(1)], "渡し済みは相手のプロセスの終わりまで持ったまま")
        XCTAssertEqual(table.release(connection: 1, requestID: 1).grants, [owner(2)])
    }

    func testInterruptFailsWaitingRequestsAndRefusesNewOnes() {
        var table = RunLockTable()
        _ = table.acquire(connection: 1, requestID: 1, keys: ["a"], mode: .exclusive)
        _ = table.acquire(connection: 2, requestID: 1, keys: ["a"], mode: .exclusive)
        let effects = table.interrupt()
        XCTAssertEqual(effects.failures.map(\.owner), [owner(2)])
        XCTAssertEqual(effects.failures.first?.reason, RunLockTable.interruptedReason)
        XCTAssertEqual(effects.grants, [])
        XCTAssertTrue(table.isGranted(owner(1)), "渡し済みは残す")
        let late = table.acquire(connection: 3, requestID: 1, keys: ["z"], mode: .shared)
        XCTAssertEqual(late.failures.map(\.owner), [owner(3)])
        XCTAssertEqual(late.grants, [])
    }

    func testReleaseAfterInterruptStillWorks() {
        var table = RunLockTable()
        _ = table.acquire(connection: 1, requestID: 1, keys: ["a"], mode: .exclusive)
        _ = table.interrupt()
        _ = table.release(connection: 1, requestID: 1)
        XCTAssertEqual(table.requestCount, 0)
        XCTAssertEqual(table.holders(of: "a"), [])
    }

    func testKeysAreIndependent() {
        var table = RunLockTable()
        _ = table.acquire(connection: 1, requestID: 1, keys: ["a"], mode: .exclusive)
        XCTAssertEqual(table.acquire(connection: 2, requestID: 1, keys: ["b"], mode: .exclusive).grants, [owner(2)])
    }

    /// キーの同一性は UTF-8 のバイト列(`String` の等価では合成済みの é と分解形が同じキーになってしまう)
    func testCanonicallyEquivalentKeysAreIndependentKeys() {
        let precomposed = "\u{E9}", decomposed = "e\u{301}"
        XCTAssertEqual(precomposed, decomposed, "Swift の String では等しい")
        var table = RunLockTable()
        XCTAssertEqual(table.acquire(connection: 1, requestID: 1, keys: [precomposed], mode: .exclusive).grants, [owner(1)])
        XCTAssertEqual(table.acquire(connection: 2, requestID: 1, keys: [decomposed], mode: .exclusive).grants, [owner(2)],
                       "別のバイト列のキーは待たない")
        XCTAssertEqual(table.holders(of: precomposed), [owner(1)])
        XCTAssertEqual(table.holders(of: decomposed), [owner(2)])
        // 同じバイト列は同じキー
        XCTAssertEqual(table.acquire(connection: 3, requestID: 1, keys: [precomposed], mode: .exclusive).grants, [])
        XCTAssertEqual(table.release(connection: 1, requestID: 1).grants, [owner(3)])
    }
}
