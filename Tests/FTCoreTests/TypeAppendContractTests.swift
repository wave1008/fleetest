// type の追記の契約(inapp F4)と、接続断の帰属・届いたか不明の文(.ips・自分の terminate)を固定する。

import XCTest
@testable import FTCore

final class TypeAppendContractTests: XCTestCase {
    private func bridgeSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("InAppBridge/Sources/InAppBridge.swift"), encoding: .utf8)
    }

    /// ref 付き type は自分の合成タップの後にキャレットを末尾へ畳む(同じ点への2連タップの選択を置換にしない)
    func testBridgeCollapsesCaretAfterEveryRefTap() throws {
        let bridge = try bridgeSource()
        XCTAssertTrue(bridge.contains("if tappedField { FTMoveCursorToEndInFirstResponder() }"))
        XCTAssertFalse(bridge.contains("if refocused { FTMoveCursorToEndInFirstResponder() }"))
    }

    func testReplacedPriorValueVerdict() {
        XCTAssertTrue(TypedInputVerdict.replacedPriorValue(priorCount: 2, typedOnly: "cd", actual: "cd"))
        XCTAssertFalse(TypedInputVerdict.replacedPriorValue(priorCount: 2, typedOnly: "cd", actual: "abcd"))
        XCTAssertFalse(TypedInputVerdict.replacedPriorValue(priorCount: 0, typedOnly: "cd", actual: "cd"))
        XCTAssertFalse(TypedInputVerdict.replacedPriorValue(priorCount: 2, typedOnly: "", actual: ""))
        XCTAssertEqual(StepNote.typeReplacedPriorValue.rawValue, "type-replaced-prior-value")
    }

    func testCrashedFateDoesNotRecommendBridgeUp() {
        let ctx = DriverErrorContext(bridge: .iosInApp, physicalDevice: false, appFate: .crashed)
        let detail = "x / the app crashed: /a.ips (SIGABRT)"
        for text in [DriverErrorMessage.unreachable(context: ctx, detail: detail),
                     DriverErrorMessage.connectionRefused(context: ctx, detail: detail)] {
            XCTAssertTrue(text.contains("crashed"), text)
            XCTAssertTrue(text.contains("/a.ips"), text)
            XCTAssertFalse(text.contains("Check: fleetest bridge up"), text)
            XCTAssertFalse(text.contains("suspended"), text)
        }
    }

    func testStoppedBySessionSaysSoAndNotCrash() {
        let ctx = DriverErrorContext(bridge: .iosInApp, physicalDevice: false, appFate: .stoppedBySession)
        let text = DriverErrorMessage.connectionRefused(context: ctx, detail: "refused")
        XCTAssertTrue(text.contains("this session stopped it"), text)
        XCTAssertTrue(text.contains("CLI: fleetest launch"), text)
        XCTAssertFalse(text.contains("killed by the OS"), text)
        XCTAssertFalse(text.contains("crashed"), text)
    }

    func testUnmeasuredFateKeepsTheDefaultMessage() {
        let ctx = DriverErrorContext(bridge: .iosInApp, physicalDevice: false)
        XCTAssertNil(ctx.appFate)
        XCTAssertTrue(DriverErrorMessage.unreachable(context: ctx, detail: "").contains("Check: fleetest bridge up."))
    }

    func testDeliveryAdviceOnlyWhenDeliveryUnknown() {
        let ctx = DriverErrorContext(bridge: .iosXCUITest, physicalDevice: false)
        XCTAssertTrue(DriverError.bridgeUnreachable(context: ctx, detail: "timed out").deliveryAdvice
            .contains("may already have been performed"))
        XCTAssertEqual(DriverError.bridgeConnectionRefused(context: ctx, detail: "").deliveryAdvice, "")
        XCTAssertEqual(DriverError.badResponse(status: 422, body: "x").deliveryAdvice, "")
    }
}
