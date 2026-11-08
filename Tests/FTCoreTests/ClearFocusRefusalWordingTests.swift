// 33周目 im4 F2: iOS の静的テキストへの clearInput(#id) の赤が、XCUITest ランナーの 422「tapping the ref …」をそのまま出した
// (DSL の利用者は ref を渡していない)。DSL の言葉(ロケータ)に直し、静的テキストなら入力欄でないことを添える

import XCTest
@testable import FTCore

final class ClearFocusRefusalWordingTests: XCTestCase {
    private func element(_ type: String) -> ElementInfo {
        ElementInfo(ref: 7, type: type, identifier: "txt_echo_single", label: "abc", value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 1)
    }
    private let step = FlowStep(action: "clearInput", locator: FlowLocator(id: "txt_echo_single"))
    private let runnerBody = "tapping the ref did not move keyboard focus to it within 1.5s — focus is still on another field,"
        + " so typing now would put the text into that field instead"

    func testRunnerRefusalIsReworded() {
        let error = StepExecutor.clearFocusRefusalInDSLTerms(DriverError.badResponse(status: 422, body: runnerBody),
                                                            step: step, element: element("staticText"))
        guard case DriverError.badResponse(422, let body) = error else { return XCTFail("\(error)") }
        XCTAssertFalse(body.contains("the ref"), body)
        XCTAssertTrue(body.contains("txt_echo_single"), body)
        XCTAssertTrue(body.contains("within 1.5s"), "ランナーの事実(待った秒数)を落とした: \(body)")
        XCTAssertTrue(body.contains("staticText"), body)
        let field = StepExecutor.clearFocusRefusalInDSLTerms(DriverError.badResponse(status: 422, body: runnerBody),
                                                            step: step, element: element("textField"))
        guard case DriverError.badResponse(422, let fieldBody) = field else { return XCTFail("\(field)") }
        XCTAssertFalse(fieldBody.contains("staticText"), fieldBody)
    }

    func testOtherErrorsPassThrough() {
        let other = StepExecutor.clearFocusRefusalInDSLTerms(DriverError.badResponse(status: 422, body: "something else"),
                                                            step: step, element: element("staticText"))
        guard case DriverError.badResponse(422, let body) = other else { return XCTFail("\(other)") }
        XCTAssertEqual(body, "something else")
    }

    /// ランナーの文言の先頭と同期(片方だけ変えると黙って直さなくなる)
    func testPrefixMatchesTheRunner() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Runner/FleetestRunnerUITests/BridgeRouter+TextInput.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("\"" + StepExecutor.runnerFocusRefusalPrefix + " within\""), "ランナーの 422 の文言が変わった")
    }
}
