// 残件台帳の CLI 系(OI-112 前半・OI-117・OI-125 の type・OI-67 F6/F7)の純粋関数を固定する。

import ArgumentParser
import FTCore
import FTServices
import Foundation
import XCTest
@testable import fleetest

final class CLIResidueFixesTests: XCTestCase {
    private func lease(startedAt: String) -> ServicesLease {
        ServicesLease(pid: 1, pidStartedAt: startedAt, kind: .owner, runtime: "apple", endpoint: "apple",
                      prefix: "fleetest-ab", generation: "g", workspace: "/ws", project: "p", profile: "r", phase: .running)
    }

    // OI-117
    func testComposeEditedAfterStartIsReported() {
        let lease = lease(startedAt: "2026-11-01T00:00:00Z")
        let after = ISO8601DateFormatter().date(from: "2026-11-01T00:05:00Z")
        let before = ISO8601DateFormatter().date(from: "2026-10-31T23:00:00Z")
        XCTAssertNotNil(ServicesCommand.composeEditedAfterStartWarning(composeModified: after, lease: lease))
        XCTAssertNil(ServicesCommand.composeEditedAfterStartWarning(composeModified: before, lease: lease))
        XCTAssertNil(ServicesCommand.composeEditedAfterStartWarning(composeModified: nil, lease: lease))
    }

    // OI-112 前半
    func testDisabledDeviceIsNamedWithEnabledFalse() {
        let disabled = [RunDeviceMachine(machine: "local", name: "iPhone A", platform: "ios")]
        let note = disabledDevicesNote(missing: ["iPhone A"], targetMachine: "local", disabled: disabled, profile: "p")
        XCTAssertTrue(note?.contains("\"enabled\": false") == true, note ?? "nil")
        XCTAssertTrue(note?.contains("profiles/runs/p.json") == true, note ?? "nil")
        XCTAssertNil(disabledDevicesNote(missing: ["iPhone B"], targetMachine: "local", disabled: disabled, profile: "p"))
        XCTAssertNil(disabledDevicesNote(missing: ["iPhone A"], targetMachine: "M1", disabled: disabled, profile: "p"))
    }

    // OI-125
    func testTypeWarnsOnTextAfterALineBreak() {
        XCTAssertNotNil(TypeCommand.lineBreakNote("ab\ncd"))
        XCTAssertNil(TypeCommand.lineBreakNote("abcd"))
        XCTAssertNil(TypeCommand.lineBreakNote("abcd\n"), "末尾の改行だけなら後ろに入らない文字が無い")
    }
}
