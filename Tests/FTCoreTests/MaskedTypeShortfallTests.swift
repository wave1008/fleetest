import XCTest
@testable import FTCore

final class MaskedTypeShortfallTests: XCTestCase {
    func testDroppedNonASCIIInEmptyFieldFails() {
        XCTAssertNotNil(StepExecutor.maskedShortfallMessage(afterValue: "", priorValue: "", text: "かな", replaced: false))
    }

    func testPartialDropFails() {
        XCTAssertNotNil(StepExecutor.maskedShortfallMessage(afterValue: "••••", priorValue: "", text: "ab日本cd", replaced: true))
        XCTAssertNotNil(StepExecutor.maskedShortfallMessage(afterValue: "•••", priorValue: "•••", text: "abc", replaced: false))
    }

    func testFullEntryPasses() {
        XCTAssertNil(StepExecutor.maskedShortfallMessage(afterValue: "••••••", priorValue: "", text: "ab日本cd", replaced: true))
        XCTAssertNil(StepExecutor.maskedShortfallMessage(afterValue: "••••••", priorValue: "•••", text: "abc", replaced: false))
        XCTAssertNil(StepExecutor.maskedShortfallMessage(afterValue: "•••••••", priorValue: "", text: "😀abc", replaced: true))
    }

    /// 読めない欄(値が空)へ ASCII を打った手と、伏せ字でない値は赤にしない
    func testUnreadableValueStaysGreen() {
        XCTAssertNil(StepExecutor.maskedShortfallMessage(afterValue: "", priorValue: "", text: "abc", replaced: true))
        XCTAssertNil(StepExecutor.maskedShortfallMessage(afterValue: "abc", priorValue: "", text: "abcd", replaced: true))
    }
}
