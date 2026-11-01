import XCTest
@testable import FTCore

final class MaskedTypeShortfallTests: XCTestCase {
    func testDroppedNonASCIIInEmptyFieldFails() {
        XCTAssertNotNil(TypedInputVerdict.maskedShortfall(priorValue: nil, priorFocused: false, afterValue: "", text: "かな"))
    }

    func testPartialDropFails() {
        XCTAssertNotNil(TypedInputVerdict.maskedShortfall(priorValue: nil, priorFocused: false, afterValue: "••••", text: "ab日本cd"))
    }

    /// 焦点を取り戻した secure 欄は打つと全部置き換わる(`•••` に `de` で `••`)
    func testAReplacedFieldOnlyNeedsTheTypedCount() {
        XCTAssertNil(TypedInputVerdict.maskedShortfall(priorValue: nil, priorFocused: false, afterValue: "••", text: "de"))
    }

    func testFullEntryPasses() {
        XCTAssertNil(TypedInputVerdict.maskedShortfall(priorValue: nil, priorFocused: false, afterValue: "••••••", text: "ab日本cd"))
        XCTAssertNil(TypedInputVerdict.maskedShortfall(priorValue: nil, priorFocused: false, afterValue: "••••••", text: "abc"))
        XCTAssertNil(TypedInputVerdict.maskedShortfall(priorValue: nil, priorFocused: false, afterValue: "•••••••", text: "😀abc"))
    }

    /// 読めない欄(値が空)へ ASCII を打った手と、伏せ字でない値は赤にしない
    func testUnreadableValueStaysGreen() {
        XCTAssertNil(TypedInputVerdict.maskedShortfall(priorValue: nil, priorFocused: false, afterValue: "", text: "abc"))
        XCTAssertNil(TypedInputVerdict.maskedShortfall(priorValue: nil, priorFocused: false, afterValue: "abc", text: "abcd"))
    }
}
