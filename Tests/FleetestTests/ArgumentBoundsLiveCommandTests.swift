import XCTest
@testable import fleetest

/// api live serve(ApiLiveServeCommand)の数値/文字列の値域チェック。MCP と同じ表
/// (FTCore.ArgumentBounds)を引く — 2箇所に値域を持たない。パース自体の型違いは
/// ApiLiveServeCommandParsingTests が別に固定しているので、ここは「型は合っているが
/// 値が無意味」(duration<=0・scale<=0・press<=0)を断ることだけを見る。
final class ArgumentBoundsLiveCommandTests: XCTestCase {

    func testNegativeDurationIsRejected() {
        let command = ApiLiveServeCommand(cmd: "drag", raw: ["cmd": "drag", "duration": -1.0])
        guard let detail = command.decodeError else { return XCTFail("duration -1 が通った") }
        XCTAssertTrue(detail.contains("duration"), detail)
        XCTAssertNil(command.duration, "値域違反の値をなだれ込ませない")
    }

    func testZeroScaleIsRejected() {
        let command = ApiLiveServeCommand(cmd: "pinch", raw: ["cmd": "pinch", "scale": 0])
        guard let detail = command.decodeError else { return XCTFail("scale 0 が通った") }
        XCTAssertTrue(detail.contains("scale"), detail)
        XCTAssertNil(command.scale)
    }

    func testNegativePressIsRejected() {
        let command = ApiLiveServeCommand(cmd: "drag", raw: ["cmd": "drag", "press": -0.5])
        guard let detail = command.decodeError else { return XCTFail("press -0.5 が通った") }
        XCTAssertTrue(detail.contains("press"), detail)
    }

    /// 正の値は従来どおり通る(値域ゲートが正常系まで壊していないこと)
    func testPositiveValuesStillParseCleanly() {
        let command = ApiLiveServeCommand(
            cmd: "pinch", raw: ["cmd": "pinch", "scale": 2.0, "duration": 0.5])
        XCTAssertNil(command.decodeError)
        XCTAssertEqual(command.scale, 2.0)
        XCTAssertEqual(command.duration, 0.5)
    }
}
