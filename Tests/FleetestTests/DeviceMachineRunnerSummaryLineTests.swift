import XCTest
@testable import fleetest

final class DeviceMachineRunnerSummaryLineTests: XCTestCase {
    private func outcome(_ code: Int32) -> FleetEntryOutcome {
        FleetEntryOutcome(host: "local", profile: "p", exitCode: code, duration: 3)
    }

    func testZeroRanWithUnhandedWorkIsNotGreen() {
        let line = DeviceMachineRunner.summaryLine(outcome: outcome(0), ran: 0, maxDuration: 3, workLeftUnhanded: true)
        XCTAssertTrue(line.hasPrefix("❌"), line)
        XCTAssertTrue(line.contains("ran=0 (no scenario reached a device)"), line)
    }

    func testZeroRanWhenOthersTookEverythingStaysGreen() {
        let line = DeviceMachineRunner.summaryLine(outcome: outcome(0), ran: 0, maxDuration: 3, workLeftUnhanded: false)
        XCTAssertTrue(line.hasPrefix("✅"), line)
        XCTAssertFalse(line.contains("no scenario reached"), line)
    }

    func testRanSomeAndStaticStayGreen() {
        XCTAssertTrue(DeviceMachineRunner.summaryLine(outcome: outcome(0), ran: 4, maxDuration: 3, workLeftUnhanded: true).hasPrefix("✅"))
        XCTAssertTrue(DeviceMachineRunner.summaryLine(outcome: outcome(0), ran: nil, maxDuration: 3, workLeftUnhanded: true).hasPrefix("✅"))
        XCTAssertTrue(DeviceMachineRunner.summaryLine(outcome: outcome(1), ran: 4, maxDuration: 3, workLeftUnhanded: false).hasPrefix("❌"))
    }
}
