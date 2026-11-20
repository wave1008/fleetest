import XCTest
@testable import FTCore

final class RunTotalsLineTests: XCTestCase {
    func testWorkQueueChildStoppedBeforeAnyScenarioDoesNotClaimAPass() throws {
        let line = try XCTUnwrap(RunTotalsLine.noScenarioRan(ranCount: 0, workQueue: true, abortReason: "no device", startCancelReason: nil))
        XCTAssertTrue(line.contains("ran no scenario"), line)
        XCTAssertFalse(line.contains("passed"), line)
    }

    func testOtherRunsKeepTheNormalLine() {
        XCTAssertNil(RunTotalsLine.noScenarioRan(ranCount: 1, workQueue: true, abortReason: "no device", startCancelReason: nil))
        XCTAssertNil(RunTotalsLine.noScenarioRan(ranCount: 0, workQueue: false, abortReason: "no device", startCancelReason: nil))
        XCTAssertNil(RunTotalsLine.noScenarioRan(ranCount: 0, workQueue: true, abortReason: nil, startCancelReason: nil))
    }

    func testChildCancelledByTheParentNeverClaimsAPassEvenWithoutAWorkQueue() throws {
        let line = try XCTUnwrap(RunTotalsLine.noScenarioRan(
            ranCount: 0, workQueue: false, abortReason: "beforeRun() failed: boom", startCancelReason: "beforeRun() failed: boom"))
        XCTAssertEqual(line, "❌ No scenario ran")
        XCTAssertFalse(line.contains("passed"), line)
        XCTAssertNil(RunTotalsLine.noScenarioRan(ranCount: 1, workQueue: false, abortReason: nil, startCancelReason: "x"))
    }
}
