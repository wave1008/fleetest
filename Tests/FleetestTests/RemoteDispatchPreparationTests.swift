// run / api run が共有する RemoteDispatchFlagPolicy.Decision.apply(注記は呼び手の出力先・拒否は ValidationError)

import ArgumentParser
import FTRemote
import XCTest
@testable import fleetest

final class RemoteDispatchFlagPolicyApplyTests: XCTestCase {

    func testAllowedSaysNothing() throws {
        var notes: [String] = []
        try RemoteDispatchFlagPolicy.Decision.allowed.apply(note: { notes.append($0) })
        XCTAssertEqual(notes, [])
    }

    func testIgnoredWithNoteGoesToTheCallersSinkAndDoesNotThrow() throws {
        var notes: [String] = []
        try RemoteDispatchFlagPolicy.Decision.ignoredWithNote("note: x").apply(note: { notes.append($0) })
        XCTAssertEqual(notes, ["note: x"])
    }

    func testRejectedThrowsTheMessageWithoutANote() {
        var notes: [String] = []
        XCTAssertThrowsError(try RemoteDispatchFlagPolicy.Decision.rejected("no").apply(note: { notes.append($0) })) {
            XCTAssertEqual(($0 as? ValidationError)?.message, "no")
        }
        XCTAssertEqual(notes, [])
    }
}
