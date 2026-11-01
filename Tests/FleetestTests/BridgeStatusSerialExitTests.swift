import XCTest
@testable import fleetest

/// `bridge status --serial X` は、端末が adb に答えなかった(状態を確かめられなかった)とき非0にする。
/// 省略(全台の一覧)や答えた端末の「止まっている」は失敗にしない。
final class BridgeStatusSerialExitTests: XCTestCase {
    func testExplicitSerialThatDidNotAnswerFails() {
        let failure = Bridge.Status.explicitSerialFailure(
            serial: "emulator-5556", explicit: true, answered: false, summary: "bridge state unknown — x")
        XCTAssertEqual(failure, "emulator-5556: bridge state unknown — x")
    }

    func testAnsweredOrListingDoesNotFail() {
        XCTAssertNil(Bridge.Status.explicitSerialFailure(
            serial: "s", explicit: true, answered: true, summary: "bridge v120 stopped"))
        XCTAssertNil(Bridge.Status.explicitSerialFailure(
            serial: "s", explicit: false, answered: false, summary: "bridge state unknown"))
    }
}
