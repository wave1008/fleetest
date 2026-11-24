import FTServices
import FTTestSupport
import Foundation
import XCTest
@testable import fleetest

/// run による `services up` の所有者の引き取り(`ServicesSession.takeOverOwners`)。生存判定と SIGTERM は差し替え口で受ける
/// = プロセスを殺さない・ランタイムに触れない。
final class ServicesOwnerTakeoverTests: XCTestCase {
    private var stateDir: URL!
    private let prefix = "fleetest-0123456789ab"

    override func setUpWithError() throws {
        stateDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("services-takeover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ServicesLeaseFile.directory(stateDir: stateDir), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDir)
    }

    private func place(_ lease: ServicesLease) throws {
        try ServicesLeaseStore.write(lease, to: ServicesLeaseFile.directory(stateDir: stateDir)
            .appendingPathComponent(ServicesLeaseFile.fileName(pid: lease.pid, prefix: prefix)),
            home: stateDir.appendingPathComponent("home").path)
    }

    private func lease(pid: Int32, kind: ServicesLease.Kind) -> ServicesLease {
        ServicesLease(pid: pid, pidStartedAt: "2026-10-14T00:00:00Z", kind: kind, runtime: "docker", endpoint: "/sock",
                      prefix: prefix, generation: "g", workspace: "/ws", project: "p", profile: "r",
                      containers: ["\(prefix)-db": "c1"], phase: .running)
    }

    /// 待っている間に排他を握っていないか(所有者も同じ排他で片付けるので、握ったまま待つと待ち合う)
    private func lockHeld() -> Bool { ServicesLock.currentHolder(prefix: prefix, stateDir: stateDir) != nil }

    func testLiveOwnerIsSignalledThenWaitedFor() throws {
        try place(lease(pid: 5001, kind: .owner))
        var signalled: [Int32] = []
        var pollsAfterSignal = 0
        var heldWhileWaiting = false
        var logs: [String] = []
        try ServicesSession.takeOverOwners(
            prefix: prefix, stateDir: stateDir,
            isAlive: { _, _ in
                guard !signalled.isEmpty else { return true }
                pollsAfterSignal += 1
                if lockHeld() { heldWhileWaiting = true }
                return pollsAfterSignal < 3   // 合図のあと 2 回は生きていて 3 回目で死ぬ
            },
            terminate: { signalled.append($0) },
            log: { logs.append($0) })
        XCTAssertEqual(signalled, [5001])
        XCTAssertEqual(pollsAfterSignal, 3, "the run waits for the owner to exit")
        XCTAssertTrue(logs.contains { $0.contains("taking over the services started by `fleetest services up` (pid 5001)") }, "\(logs)")
        XCTAssertFalse(heldWhileWaiting, "the lock is released before waiting")
        XCTAssertFalse(lockHeld())
    }

    /// 引き取った所有者の控えを返す = run の片付けの後に同じ指定で起こし直す材料(DR-194)
    func testTakeoverReturnsTheOwnersItStopped() throws {
        try place(lease(pid: 5004, kind: .owner))
        var signalled = false
        let taken = try ServicesSession.takeOverOwners(prefix: prefix, stateDir: stateDir,
                                                       isAlive: { _, _ in !signalled },
                                                       terminate: { _ in signalled = true }, log: { _ in })
        XCTAssertEqual(taken.map(\.pid), [5004])
        XCTAssertEqual(ServicesSession.ownerRestores(taken),
                       [.init(project: "p", profile: "r", physical: false, serials: [])])
    }

    /// LAN へ束縛した公開ポートがあれば `--physical`、`adb reverse` のシリアルは `--serial` で起こし直す。同じ project・profile は1回
    func testOwnerRestoreCarriesThePhysicalOptions() {
        var physical = lease(pid: 1, kind: .owner)
        physical.publishedPorts = [.init(hostIP: "127.0.0.1", hostPort: 8090, proto: "tcp", service: "server"),
                                   .init(hostIP: "192.168.1.10", hostPort: 8090, proto: "tcp", service: "server")]
        physical.adbReverse = [.init(serial: "R2", hostPort: 8090), .init(serial: "R1", hostPort: 8090), .init(serial: "R1", hostPort: 9000)]
        XCTAssertEqual(ServicesSession.ownerRestores([physical, lease(pid: 2, kind: .owner)]),
                       [.init(project: "p", profile: "r", physical: true, serials: ["R1", "R2"])])
    }

    /// 引き取り後に claimPrefix 等で開始が失敗した run は、止めた所有者を起こし直す(控えを失わない)
    func testFailedStartAfterTakeoverInstructsRestoringTheOwners() {
        let taken = [lease(pid: 5010, kind: .owner)]
        XCTAssertEqual(ServicesSession.ownerRestoreDecision(taken: taken, interrupted: false, ownServicesRemain: false, executableFound: true),
                       .restore([.init(project: "p", profile: "r", physical: false, serials: [])]))
        XCTAssertEqual(ServicesSession.ownerRestoreDecision(taken: [], interrupted: false, ownServicesRemain: false, executableFound: true),
                       .nothing)
        XCTAssertEqual(ServicesSession.ownerRestoreDecision(taken: taken, interrupted: true, ownServicesRemain: false, executableFound: true),
                       .skip(reason: "the run was interrupted"))
        XCTAssertEqual(ServicesSession.ownerRestoreDecision(taken: taken, interrupted: false, ownServicesRemain: true, executableFound: true),
                       .skip(reason: "this run's services could not all be removed"))
        XCTAssertEqual(ServicesSession.ownerRestoreDecision(taken: taken, interrupted: false, ownServicesRemain: false, executableFound: false),
                       .skip(reason: "the fleetest executable was not found"))
    }

    /// 待ちが尽きて投げても、止めた所有者は `collected` で呼び手に渡っている(途中失敗で失われない)
    func testOwnersAreHandedOverBeforeAFailedWait() throws {
        try place(lease(pid: 5011, kind: .owner))
        var collected: [ServicesLease] = []
        XCTAssertThrowsError(try ServicesSession.takeOverOwners(
            prefix: prefix, stateDir: stateDir, budgetOverrideSeconds: 0,
            collected: { collected = $0 },
            isAlive: { _, _ in true }, terminate: { _ in }, log: { _ in }))
        XCTAssertEqual(collected.map(\.pid), [5011])
    }

    func testLiveRunLeaseIsNotSignalled() throws {
        try place(lease(pid: 5002, kind: .run))
        var signalled: [Int32] = []
        try ServicesSession.takeOverOwners(prefix: prefix, stateDir: stateDir, isAlive: { _, _ in true },
                                           terminate: { signalled.append($0) }, log: { _ in })
        XCTAssertEqual(signalled, [], "a run's lease is left to claimPrefix (refused there)")
    }

    func testOrphanOwnerLeaseIsNotSignalled() throws {
        try place(lease(pid: 5003, kind: .owner))
        var signalled: [Int32] = []
        try ServicesSession.takeOverOwners(prefix: prefix, stateDir: stateDir, isAlive: { _, _ in false },
                                           terminate: { signalled.append($0) }, log: { _ in })
        XCTAssertEqual(signalled, [], "a dead owner's lease is reaped by claimPrefix, not signalled")
    }

    func testOwnerThatDoesNotExitIsReportedWithItsPid() throws {
        try place(lease(pid: 5004, kind: .owner))
        var signalled = false
        var heldWhileWaiting = false
        XCTAssertThrowsError(try ServicesSession.takeOverOwners(
            prefix: prefix, stateDir: stateDir, budgetOverrideSeconds: 0.3,
            isAlive: { _, _ in
                if signalled, lockHeld() { heldWhileWaiting = true }
                return true
            }, terminate: { _ in signalled = true }, log: { _ in })) { error in
            let detail = (error as? ServicesError)?.detail ?? ""
            XCTAssertTrue(detail.contains("(`fleetest services up`, pid 5004) has not exited"), detail)
            XCTAssertTrue(detail.contains("stop it, then retry"), detail)
        }
        XCTAssertFalse(heldWhileWaiting, "the lock is released before waiting")
        XCTAssertFalse(lockHeld())
    }

    func testHeldByOtherWording() {
        let run = lease(pid: 1, kind: .run)
        let owner = lease(pid: 2, kind: .owner)
        XCTAssertEqual(ServicesSession.heldByOther(run, mine: .run), "run pid 1 holds these services; wait for that run to finish")
        XCTAssertEqual(ServicesSession.heldByOther(run, mine: .owner), "run pid 1 holds these services; wait for that run to finish")
        XCTAssertEqual(ServicesSession.heldByOther(owner, mine: .owner),
                       "these services are already up (`fleetest services up` (pid 2)); use them, or run `fleetest services down` first")
        XCTAssertEqual(ServicesSession.heldByOther(owner, mine: .run),
                       "`fleetest services up` (pid 2) holds these services; stop them with `fleetest services down` first")
    }
}
