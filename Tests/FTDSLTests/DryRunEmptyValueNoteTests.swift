import XCTest
import FTCore
@testable import FTDSL

/// dry-run で値が空だった行(DR-211): 空の入力は断らずに注記、文字の検証の空の期待値も注記。デバイスでの実行は空の入力を断る
final class DryRunEmptyValueNoteTests: XCTestCase {
    func testEmptyTypeIsRefusedOnlyOutsideDryRun() {
        XCTAssertNotNil(emptyTypeRefusal("", replace: false, dryRun: false))
        XCTAssertNil(emptyTypeRefusal("", replace: false, dryRun: true))
        XCTAssertNil(emptyTypeRefusal("", replace: true, dryRun: false))
        XCTAssertNil(emptyTypeRefusal("abc", replace: false, dryRun: false))
    }

    func testEmptyTypeGetsTheNote() {
        let step = FlowStep(action: "type", text: "")
        XCTAssertEqual(FTDriveCore.dryRunEmptyValueNotes(step), [.dryRunEmptyText])
        var replacing = FlowStep(action: "type", text: "")
        replacing.replace = true
        XCTAssertEqual(FTDriveCore.dryRunEmptyValueNotes(replacing), [])
        XCTAssertEqual(FTDriveCore.dryRunEmptyValueNotes(FlowStep(action: "type", text: "x")), [])
    }

    func testEmptyExpectedTextGetsTheNote() {
        let empty = FlowStep(assert: "textEquals", locator: FlowLocator(id: "txt"), expected: "")
        XCTAssertEqual(FTDriveCore.dryRunEmptyValueNotes(empty), [.dryRunEmptyExpected])
        let filled = FlowStep(assert: "textEquals", locator: FlowLocator(id: "txt"), expected: "a")
        XCTAssertEqual(FTDriveCore.dryRunEmptyValueNotes(filled), [])
    }
}
