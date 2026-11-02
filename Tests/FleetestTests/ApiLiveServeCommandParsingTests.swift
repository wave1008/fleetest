import XCTest
@testable import fleetest

/// api live serve の NDJSON パース(ApiLiveServeCommand)。実地 L3: 型違いの引数
/// ({"cmd":"pinch","scale":"2"} 等)が JSONDecoder の全体失敗で「JSON でない行」と
/// 見分けられず無応答のまま黙殺され、拡張の SERVE_REQUEST_TIMEOUT で serve ごと
/// 再起動していた。cmd が読めた行は decodeError に理由を持ち帰ることを固定する。
final class ApiLiveServeCommandParsingTests: XCTestCase {

    func testQuotedNumberIsRejectedWithATypedMessage() {
        let command = ApiLiveServeCommand(cmd: "pinch", raw: ["cmd": "pinch", "scale": "2"])
        guard let detail = command.decodeError else { return XCTFail("型違いは decodeError に載せる") }
        XCTAssertTrue(detail.contains("scale must be a number"), detail)
        XCTAssertTrue(detail.contains("the string \"2\""), detail)
        XCTAssertNil(command.scale, "型違いの値をなだれ込ませない")
    }

    func testNumberInAStringFieldIsRejectedWithATypedMessage() {
        let command = ApiLiveServeCommand(cmd: "type", raw: ["cmd": "type", "text": 123])
        guard let detail = command.decodeError else { return XCTFail("型違いは decodeError に載せる") }
        XCTAssertTrue(detail.contains("text must be a string"), detail)
        XCTAssertNil(command.text)
    }

    /// 複数同時に型が違っても最初の1件だけを持ち帰る(文言に困らない範囲で十分)
    func testOnlyTheFirstTypeErrorIsKept() {
        let command = ApiLiveServeCommand(
            cmd: "drag", raw: ["cmd": "drag", "fromX": "1", "fromY": "2"])
        guard let detail = command.decodeError else { return XCTFail("型違いは decodeError に載せる") }
        XCTAssertTrue(detail.contains("fromX"), detail)
        XCTAssertFalse(detail.contains("fromY"), detail)
    }

    /// **JSON の true は NSNumber(CFBoolean)で来て `as? Int` / `as? Double` を 1 として通る**(負荷テストで
    /// 真偽値が数値としてドライバまで届いた)。実入力と同じく JSONSerialization で読む
    /// (Swift の `true` リテラルは CFBoolean にならないので、辞書リテラルでは再現しない)
    private func parsed(_ json: String) throws -> ApiLiveServeCommand {
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return ApiLiveServeCommand(cmd: try XCTUnwrap(raw["cmd"] as? String), raw: raw)
    }

    func testJSONBooleanIsRejectedForACoordinate() throws {
        let command = try parsed(#"{"cmd":"tap","x":true,"y":1}"#)
        guard let detail = command.decodeError else { return XCTFail("true を x 1 として通さない") }
        XCTAssertTrue(detail.contains("x must be a number (got the boolean true)"), detail)
        XCTAssertNil(command.x)
    }

    func testJSONBooleanIsRejectedForANumberField() throws {
        let command = try parsed(#"{"cmd":"pinch","scale":false}"#)
        guard let detail = command.decodeError else { return XCTFail("false を scale 0 として通さない") }
        XCTAssertTrue(detail.contains("scale must be a number (got the boolean false)"), detail)
        XCTAssertNil(command.scale)
    }

    func testJSONBooleanIsRejectedForAGesturePoint() throws {
        let command = try parsed(#"{"cmd":"gesture","fingers":[{"points":[{"x":1,"y":2,"t":true}]}]}"#)
        XCTAssertNotNil(command.decodeError, "t: true を 1 秒として通さない")
        XCTAssertNil(command.fingers)
    }

    /// 逆向き: 数値の 1 を「the boolean true」と書かない(`as Bool` は NSNumber の 0/1 にも当たる)
    func testJSONNumberOneInAStringFieldIsNotDescribedAsABoolean() throws {
        let command = try parsed(#"{"cmd":"type","text":1}"#)
        guard let detail = command.decodeError else { return XCTFail("型違いは decodeError に載せる") }
        XCTAssertTrue(detail.contains("text must be a string (got 1)"), detail)
    }

    /// NUL は入口で断る(MCP と同じ文言。外部コマンドへ流れると Process が abort する)
    func testNULInAStringFieldIsRejected() throws {
        let command = try parsed(#"{"cmd":"type","text":"a\u0000b"}"#)
        XCTAssertEqual(command.decodeError, "text must not contain a NUL character (\\u0000)")
        XCTAssertNil(command.text)
    }

    /// 配列の欄の型違いに「JSON の文字列を渡せ」と言わない
    func testArrayFieldTypeErrorAsksForAnArray() throws {
        let command = try parsed(#"{"cmd":"gesture","fingers":-1}"#)
        guard let detail = command.decodeError else { return XCTFail("型違いは decodeError に載せる") }
        XCTAssertTrue(detail.hasSuffix("pass a JSON array"), detail)
    }

    func testCorrectTypesParseCleanlyWithNoDecodeError() {
        let command = ApiLiveServeCommand(
            cmd: "pinch", raw: ["cmd": "pinch", "scale": 2.5, "duration": 0.7])
        XCTAssertNil(command.decodeError)
        XCTAssertEqual(command.scale, 2.5)
        XCTAssertEqual(command.duration, 0.7)
    }

    /// **読まない欄は撃たずに断る**(黙って捨てると ref つきの type がフォーカス中の別の欄へ打つ・ref つきの pinch が全画面に化ける)
    func testRefIsRefusedRatherThanIgnored() {
        let typed = ApiLiveServeCommand(cmd: "type", raw: ["cmd": "type", "text": "secret", "ref": 3])
        XCTAssertEqual(typed.decodeError, ApiLiveServeCommand.unknownKeyError("ref"))
        XCTAssertFalse(typed.drivesDevice, "断った行は撃たない")
        let pinch = ApiLiveServeCommand(cmd: "pinch", raw: ["cmd": "pinch", "scale": 2, "ref": 3])
        XCTAssertEqual(pinch.decodeError, ApiLiveServeCommand.unknownKeyError("ref"))
    }

    func testAnyUnknownKeyIsRefused() {
        let command = ApiLiveServeCommand(cmd: "tap", raw: ["cmd": "tap", "x": 1, "y": 2, "bundle": "com.example"])
        XCTAssertEqual(command.decodeError, "bundle is not an argument of live control — nothing was sent")
    }

    /// 拡張が送る形(monitorLiveController.ts)はどれも断らない
    func testEveryShapeTheExtensionSendsPasses() {
        let shapes: [[String: Any]] = [
            ["cmd": "refresh"], ["cmd": "tap", "x": 1, "y": 2], ["cmd": "type", "text": "a"],
            ["cmd": "drag", "fromX": 1, "fromY": 2, "toX": 3, "toY": 4, "press": 0.1, "duration": 0.3],
            ["cmd": "gesture", "fingers": [["points": [["x": 1, "y": 2, "t": 0]]]], "maxGestureSeconds": 12],
            ["cmd": "press", "x": 1, "y": 2, "duration": 1], ["cmd": "doubleTap", "x": 1, "y": 2],
            ["cmd": "pinch", "scale": 2, "duration": 0.5], ["cmd": "home"], ["cmd": "appSwitcher"],
            ["cmd": "fold", "state": "fold"],
        ]
        for raw in shapes {
            XCTAssertNil(ApiLiveServeCommand(cmd: raw["cmd"] as! String, raw: raw).decodeError, "\(raw)")
        }
    }

    /// 表(knownKeys)は init が読む欄の全数と一致する(欄を足して表へ載せ忘れると、その欄を送る行が全部断られる)
    func testKnownKeysMatchTheFieldsTheInitReads() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/ApiLiveCommand.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"Self\.\w+Field\(raw, "(\w+)""#)
        let read = Set(regex.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap {
            Range($0.range(at: 1), in: code).map { String(code[$0]) }
        })
        XCTAssertGreaterThan(read.count, 10, "走査が init に届いていない")
        XCTAssertEqual(read.union(["cmd"]), ApiLiveServeCommand.knownKeys)
    }

    /// JSON の整数値({"scale":2}、小数点なし)も number として通す(NSNumber は Int/Double の
    /// どちらでも来うる。整数値の double 引数を誤って型違いと断らない)
    func testWholeNumberJSONValuePassesADoubleField() {
        let command = ApiLiveServeCommand(cmd: "pinch", raw: ["cmd": "pinch", "scale": 2])
        XCTAssertNil(command.decodeError)
        XCTAssertEqual(command.scale, 2.0)
    }

    func testAbsentFieldsStayNilWithoutAnError() {
        let command = ApiLiveServeCommand(cmd: "refresh", raw: ["cmd": "refresh"])
        XCTAssertNil(command.decodeError)
        XCTAssertNil(command.x)
        XCTAssertNil(command.text)
    }
}
