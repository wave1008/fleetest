// OI-116: services reset --force の件数は所有者が自分で片付けた後に数える。止めた事実を添えるかを固定する。

import XCTest
@testable import fleetest

final class ServicesResetSummaryTests: XCTestCase {
    func testSummaryNamesStoppedOwnerWhenOneWasStopped() {
        let line = ServicesCommand.Reset.summaryLine(containers: 0, networks: 0, volumes: 0, leases: 1, stoppedOwners: true)
        XCTAssertTrue(line.contains("0 container(s)"), line)
        XCTAssertTrue(line.contains("stopped owner"), line)
    }

    func testSummaryHasNoNoteWhenNoOwnerWasStopped() {
        let line = ServicesCommand.Reset.summaryLine(containers: 2, networks: 1, volumes: 0, leases: 1, stoppedOwners: false)
        XCTAssertEqual(line, "→ services reset: 2 container(s), 1 network(s), 0 volume(s) removed; 1 lease(s) cleared")
    }
}
