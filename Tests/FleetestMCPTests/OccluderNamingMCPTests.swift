// MCP の注記も DSL と同じく、Android の Flutter の同じウィンドウの組は覆いの相手を名指さず、名前の無い注意だけ出す(DR-230)
import XCTest
import FTCore
@testable import fleetest_mcp

final class OccluderNamingMCPTests: XCTestCase {
    func testFlutterGetsAnUnnamedCautionAndOthersKeepTheName() {
        let target = ElementInfo(ref: 1, type: "button", identifier: "fab_extended", label: "追加", value: nil,
                                 placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 300, width: 400, height: 60), depth: 1)
        let row = ElementInfo(ref: 2, type: "button", identifier: "row_f_10", label: "行 10", value: nil,
                              placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 320, width: 400, height: 60), depth: 1)
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        let flutter = RefGuard.overlapWarning(found: target, in: [target, row], screen: screen,
                                              isAndroid: true, framework: .flutter, operation: "tap")
        XCTAssertFalse(flutter.contains("row_f_10"), flutter)
        XCTAssertTrue(flutter.contains("may be covered by another element"), flutter)
        let compose = RefGuard.overlapWarning(found: target, in: [target, row], screen: screen,
                                              isAndroid: true, framework: .compose, operation: "tap")
        XCTAssertTrue(compose.contains("row_f_10"), compose)
        XCTAssertFalse(compose.contains("may be covered by another element"), compose)
    }
}
