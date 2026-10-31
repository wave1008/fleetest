import XCTest
@testable import FTCore

final class MaskedTypeShortfallTests: XCTestCase {
    func testDroppedNonASCIIInEmptyFieldFails() {
        XCTAssertNotNil(StepExecutor.maskedShortfallMessage(afterValue: "", text: "かな"))
    }

    func testPartialDropFails() {
        XCTAssertNotNil(StepExecutor.maskedShortfallMessage(afterValue: "••••", text: "ab日本cd"))
    }

    /// 焦点を取り戻した secure 欄は打つと全部置き換わる(`•••` に `de` で `••`)
    func testAReplacedFieldOnlyNeedsTheTypedCount() {
        XCTAssertNil(StepExecutor.maskedShortfallMessage(afterValue: "••", text: "de"))
    }

    func testFullEntryPasses() {
        XCTAssertNil(StepExecutor.maskedShortfallMessage(afterValue: "••••••", text: "ab日本cd"))
        XCTAssertNil(StepExecutor.maskedShortfallMessage(afterValue: "••••••", text: "abc"))
        XCTAssertNil(StepExecutor.maskedShortfallMessage(afterValue: "•••••••", text: "😀abc"))
    }

    /// 読めない欄(値が空)へ ASCII を打った手と、伏せ字でない値は赤にしない
    func testUnreadableValueStaysGreen() {
        XCTAssertNil(StepExecutor.maskedShortfallMessage(afterValue: "", text: "abc"))
        XCTAssertNil(StepExecutor.maskedShortfallMessage(afterValue: "abc", text: "abcd"))
    }
}
