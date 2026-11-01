// ft_batch の ref なし入力(type / clearInput / pressEnter)の断りの決定(前面が別アプリなら撃たずに断る)

import XCTest
import FTCore
@testable import fleetest_mcp

final class RefLessBatchRefusalTests: XCTestCase {
    private let front = " (warning: the front app is com.other)"

    func testRefusesOnlyAnAndroidRefLessInputWithAForeignFrontApp() throws {
        for action in ["type", "clearInput", "pressEnter"] {
            let refusal = try XCTUnwrap(MCPServer.refLessBatchRefusal(FlowStep(action: action), isAndroid: true, frontWarning: front), action)
            XCTAssertTrue(refusal.contains("nothing was sent"), refusal)
            XCTAssertTrue(refusal.contains("com.other"), refusal)
        }
        // 前面が自分のアプリ(警告なし)・iOS(ランナーが断る)・ref あり・入力でない手は断らない
        XCTAssertNil(MCPServer.refLessBatchRefusal(FlowStep(action: "type"), isAndroid: true, frontWarning: ""))
        XCTAssertNil(MCPServer.refLessBatchRefusal(FlowStep(action: "type"), isAndroid: false, frontWarning: front))
        XCTAssertNil(MCPServer.refLessBatchRefusal(
            FlowStep(action: "type", locator: FlowLocator(id: "field")), isAndroid: true, frontWarning: front))
        XCTAssertNil(MCPServer.refLessBatchRefusal(FlowStep(action: "tap"), isAndroid: true, frontWarning: front))
    }
}
