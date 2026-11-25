import XCTest
@testable import FTBridgeClient

/// adopt の止めて起動し直す区間を ProvisionLock の外に出さない持ち手
final class ProvisionLockHoldTests: XCTestCase {

    func testShouldReleaseTruthTable() {
        XCTAssertFalse(ProvisionLockHold.shouldRelease(barrierDone: false, restarts: 0, finished: false))
        XCTAssertFalse(ProvisionLockHold.shouldRelease(barrierDone: true, restarts: 1, finished: false))
        XCTAssertTrue(ProvisionLockHold.shouldRelease(barrierDone: true, restarts: 0, finished: false))
        XCTAssertTrue(ProvisionLockHold.shouldRelease(barrierDone: false, restarts: 2, finished: true))
    }

    private func makeDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProvisionLockHoldTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// 別の open で LOCK_NB を試す = 他プロセスから見た「握られているか」
    private func isLockedByOthers(_ dir: URL) -> Bool {
        let fd = open(dir.appendingPathComponent("provision.lock").path, O_RDWR)
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
        return true
    }

    private func makeHold(_ dir: URL) async throws -> ProvisionLockHold {
        let lock = try ProvisionLock(stateDir: dir)
        await lock.acquire()
        return ProvisionLockHold(held: lock, stateDir: dir)
    }

    func testRestartInProgressDelaysEarlyRelease() async throws {
        let dir = makeDir()
        let hold = try await makeHold(dir)
        await hold.beginRestart()
        hold.barrierCompleted()
        XCTAssertTrue(isLockedByOthers(dir), "起動し直し中は barrier が揃っても解かない")
        hold.endRestart()
        XCTAssertFalse(isLockedByOthers(dir), "起動し直しが済めば解く")
    }

    func testBarrierWithoutRestartReleasesImmediately() async throws {
        let dir = makeDir()
        let hold = try await makeHold(dir)
        XCTAssertTrue(isLockedByOthers(dir))
        hold.barrierCompleted()
        XCTAssertFalse(isLockedByOthers(dir))
    }

    func testRestartAfterEarlyReleaseReacquiresAndReleases() async throws {
        let dir = makeDir()
        let hold = try await makeHold(dir)
        hold.barrierCompleted()
        XCTAssertFalse(isLockedByOthers(dir))
        await hold.beginRestart()
        XCTAssertTrue(isLockedByOthers(dir), "解けた後の起動し直しは取り直す")
        hold.endRestart()
        XCTAssertFalse(isLockedByOthers(dir))
    }

    func testConcurrentRestartsShareOneHold() async throws {
        let dir = makeDir()
        let hold = try await makeHold(dir)
        hold.barrierCompleted()
        async let a: Void = hold.beginRestart()
        async let b: Void = hold.beginRestart()
        _ = await (a, b)
        hold.endRestart()
        XCTAssertTrue(isLockedByOthers(dir), "もう片方が起動し直し中")
        hold.endRestart()
        XCTAssertFalse(isLockedByOthers(dir))
    }

    func testFinishReleasesEvenDuringRestart() async throws {
        let dir = makeDir()
        let hold = try await makeHold(dir)
        await hold.beginRestart()
        hold.finish()
        XCTAssertFalse(isLockedByOthers(dir))
    }

    func testProvisionerWiresAdoptRestartThroughHold() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/FTBridgeClient/BridgeProvisioner.swift"),
                              encoding: .utf8)
        XCTAssertTrue(text.contains("lockHold?.beginRestart"), "adopt の stopAndRelaunch はロックを保持する")
        XCTAssertTrue(text.contains("lockHold.barrierCompleted()"), "早期解放は持ち手を通す")
    }
}
