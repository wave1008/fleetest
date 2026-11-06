import XCTest
@testable import FTCore

/// XCUITest がアラートの各ボタンを 2 つずつ返す形の重複除き(OI-180 ③)。ランナーの読み(`SystemAlertProbe.buttonLabels`)が使う
final class AlertButtonDedupeTests: XCTestCase {
    private func rect(_ x: Double) -> FTRect { FTRect(x: x, y: 500, width: 120, height: 44) }

    func testDuplicatedButtonsCollapseInFirstSeenOrder() {
        let labels = BridgeAPI.uniqueAlertButtonLabels([
            ("Don't Allow", rect(20)), ("Allow", rect(160)), ("Don't Allow", rect(20)), ("Allow", rect(160)),
        ])
        XCTAssertEqual(labels, ["Don't Allow", "Allow"])
    }

    func testSameLabelAtAnotherPositionIsKeptAndEmptyLabelsDropped() {
        let labels = BridgeAPI.uniqueAlertButtonLabels([("OK", rect(20)), ("", rect(90)), ("OK", rect(160))])
        XCTAssertEqual(labels, ["OK", "OK"], "位置の違う同じラベルは別のボタン")
    }
}
