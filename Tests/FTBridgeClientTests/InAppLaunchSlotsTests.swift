// in-app 起動の機械全体の枠(MachineWideSlots / InAppLaunchSlots)。別プロセスは別インスタンス(同じロックファイル)で代える

import XCTest
import FTCore
import Foundation
@testable import FTBridgeClient

final class InAppLaunchSlotsTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inapp-launch-slots-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeProcess() -> MachineWideSlots {
        let slots = MachineWideSlots(concurrency: InAppLaunchSlots.concurrency, filePrefix: "inapp-launch.lock")
        slots.lockDirectoryForTesting = directory
        return slots
    }

    func testWidthIsPinned() {
        XCTAssertEqual(InAppLaunchSlots.concurrency, 2)
        XCTAssertEqual(BridgeProvisioner.launchSlotWidth, 2)
    }

    /// 別プロセス(別の fd 集合)を合わせても2枠までで、返せば次が取れる
    func testTwoProcessesTogetherCannotHoldMoreThanTwo() {
        let p1 = makeProcess(), p2 = makeProcess()
        XCTAssertTrue(p1.acquireWithoutWaiting(owner: "A"))
        XCTAssertTrue(p2.acquireWithoutWaiting(owner: "B"))
        XCTAssertFalse(p1.acquireWithoutWaiting(owner: "C"))
        XCTAssertFalse(p2.acquireWithoutWaiting(owner: "D"))
        p2.release(owner: "B")
        XCTAssertTrue(p1.acquireWithoutWaiting(owner: "C"))
        XCTAssertFalse(p2.acquireWithoutWaiting(owner: "D"))
        p1.resetForTesting(); p2.resetForTesting()
    }

    func testSingleProcessKeepsWidthTwo() {
        let p = makeProcess()
        XCTAssertTrue(p.acquireWithoutWaiting(owner: "A"))
        XCTAssertTrue(p.acquireWithoutWaiting(owner: "B"))
        XCTAssertFalse(p.acquireWithoutWaiting(owner: "C"))
        p.resetForTesting()
    }

    func testSlotIsReleasedOnCompletionAndOnThrow() async throws {
        let p1 = makeProcess(), p2 = makeProcess()
        try await p1.withSlot(owner: "A", what: "x", log: { _ in }) {
            XCTAssertTrue(p2.acquireWithoutWaiting(owner: "B"))
            XCTAssertFalse(p2.acquireWithoutWaiting(owner: "C"), "A and B hold both slots")
            p2.release(owner: "B")
        }
        struct Boom: Error {}
        do {
            try await p1.withSlot(owner: "A2", what: "x", log: { _ in }) { throw Boom() }
            XCTFail("must throw")
        } catch is Boom {}
        XCTAssertTrue(p2.acquireWithoutWaiting(owner: "P"))
        XCTAssertTrue(p2.acquireWithoutWaiting(owner: "Q"), "both slots were returned")
        p1.resetForTesting(); p2.resetForTesting()
    }

    func testWaiterGetsTheSlotWhenAnotherProcessReleasesAndCancelAborts() async throws {
        let p1 = makeProcess(), p2 = makeProcess()
        XCTAssertTrue(p1.acquireWithoutWaiting(owner: "A"))
        XCTAssertTrue(p1.acquireWithoutWaiting(owner: "B"))
        let cancelled = Task { try await p2.acquire(owner: "W", what: "x", log: { _ in }) }
        try await Task.sleep(nanoseconds: 100_000_000)
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("must be cancelled") } catch is CancellationError {}
        let waiter = Task { try await p2.acquire(owner: "W", what: "x", log: { _ in }) }
        try await Task.sleep(nanoseconds: 100_000_000)
        p1.release(owner: "A")
        try await waiter.value
        XCTAssertEqual(p2.owners().filter { $0.hasSuffix(" W") }.count, 1)
        p1.resetForTesting(); p2.resetForTesting()
    }

    /// 枠に並ぶ台は機械全体の枠を通る(プロセス内だけの絞りに戻さない)
    func testProvisionerRoutesSlottedDevicesThroughTheMachineWideSlot() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let code = try String(contentsOf: root.appendingPathComponent("Sources/FTBridgeClient/BridgeProvisioner.swift"),
                              encoding: .utf8)
        let call = try XCTUnwrap(code.range(of: "InAppLaunchSlots.shared.withSlot("))
        XCTAssertTrue(code[..<call.lowerBound].suffix(400).contains("entry.slotted"),
                      "slot must be conditional on slotted devices")
        XCTAssertTrue(code.contains("static let launchSlotWidth = InAppLaunchSlots.concurrency"))
        XCTAssertFalse(code.contains("static let launchSlotWidth = 2"))
    }
}
