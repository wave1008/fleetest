import XCTest
@testable import FTCore

final class WorkQueueProtocolTests: XCTestCase {

    func testWantRoundTripAndExactWireForm() throws {
        let want = WorkQueueProtocol.Want(req: 7, lane: "iPhone 17", platform: "ios")
        let line = WorkQueueProtocol.encode(want)
        XCTAssertEqual(line, #"{"ftWork":{"lane":"iPhone 17","op":"want","platform":"ios","req":7}}"#)
        XCTAssertFalse(line.contains("\n"))
        XCTAssertEqual(WorkQueueProtocol.decodeWant(line), want)
    }

    func testReplyWithIDRoundTrip() {
        let reply = WorkQueueProtocol.Reply(req: 3, unit: ScenarioUnitKey(id: "Login.S0010", variant: nil))
        let line = WorkQueueProtocol.encode(reply)
        XCTAssertEqual(line, #"{"ftWork":{"id":"Login.S0010","req":3}}"#)
        let decoded = WorkQueueProtocol.decodeReply(line)
        XCTAssertEqual(decoded, reply)
        XCTAssertEqual(decoded?.unit, ScenarioUnitKey(id: "Login.S0010", variant: nil))
    }

    /// バリアント付きの単位は `variant` を足した形で往復する(バリアントの無い行の形は上のテストが固定)
    func testReplyAndNotApplicableCarryTheVariantOnTheWire() {
        let unit = ScenarioUnitKey(id: "Login.S0010", variant: "dark")
        let reply = WorkQueueProtocol.Reply(req: 3, unit: unit)
        let line = WorkQueueProtocol.encode(reply)
        XCTAssertEqual(line, #"{"ftWork":{"id":"Login.S0010","req":3,"variant":"dark"}}"#)
        XCTAssertEqual(WorkQueueProtocol.decodeReply(line)?.unit, unit)
        let na = WorkQueueProtocol.NotApplicable(req: 5, unit: unit, lane: "a", platform: "ios", dep: false)
        let naLine = WorkQueueProtocol.encode(na)
        XCTAssertTrue(naLine.contains(#""variant":"dark""#))
        XCTAssertEqual(WorkQueueProtocol.decodeNotApplicable(naLine)?.unit, unit)
        let plain = WorkQueueProtocol.NotApplicable(req: 5, unit: ScenarioUnitKey(id: "A.b", variant: nil), lane: "a", platform: "ios", dep: false)
        XCTAssertFalse(WorkQueueProtocol.encode(plain).contains("variant"), "バリアントの無い行に variant を載せない")
    }

    /// `kept`(子 → 親・返事なし)の往復。他の種類の行として読まれない・他の行を kept と読まない
    func testKeptRoundTripAndIsNotConfusedWithOtherLines() {
        let unit = ScenarioUnitKey(id: "Fold.S1", variant: "dark")
        let line = WorkQueueProtocol.encode(WorkQueueProtocol.Kept(unit: unit, on: true))
        XCTAssertTrue(WorkQueueProtocol.isWorkLine(line))
        XCTAssertEqual(WorkQueueProtocol.decodeKept(line), WorkQueueProtocol.Kept(unit: unit, on: true))
        XCTAssertNil(WorkQueueProtocol.decodeWant(line))
        XCTAssertNil(WorkQueueProtocol.decodeNotApplicable(line))
        XCTAssertNil(WorkQueueProtocol.decodeReply(line))
        let off = WorkQueueProtocol.encode(WorkQueueProtocol.Kept(unit: ScenarioUnitKey(id: "A.b", variant: nil), on: false))
        XCTAssertEqual(WorkQueueProtocol.decodeKept(off)?.on, false)
        XCTAssertFalse(off.contains("variant"), "バリアントの無い行に variant を載せない")
        XCTAssertNil(WorkQueueProtocol.decodeKept(WorkQueueProtocol.encode(WorkQueueProtocol.Want(req: 1, lane: "a", platform: "ios"))))
    }

    /// 見直しの返事(`again`)は返事として読め、「もう無い」とも単位とも混ざらない
    func testReplyAgainRoundTrip() {
        let line = WorkQueueProtocol.encode(WorkQueueProtocol.Reply(req: 7, again: true))
        let reply = WorkQueueProtocol.decodeReply(line)
        XCTAssertEqual(reply?.again, true)
        XCTAssertNil(reply?.none)
        XCTAssertNil(reply?.unit)
        XCTAssertFalse(WorkQueueProtocol.encode(WorkQueueProtocol.Reply(req: 7, none: true)).contains("again"))
    }

    func testReplyNoneRoundTrip() {
        let reply = WorkQueueProtocol.Reply(req: 4, none: true)
        let line = WorkQueueProtocol.encode(reply)
        XCTAssertEqual(line, #"{"ftWork":{"none":true,"req":4}}"#)
        let decoded = WorkQueueProtocol.decodeReply(line)
        XCTAssertEqual(decoded, reply)
        XCTAssertNil(decoded?.unit)
    }

    func testNonAsciiScenarioIDRoundTrips() {
        let reply = WorkQueueProtocol.Reply(req: 1, unit: ScenarioUnitKey(id: "ログイン.S0010", variant: nil))
        XCTAssertEqual(WorkQueueProtocol.decodeReply(WorkQueueProtocol.encode(reply)), reply)
    }

    func testDecodeToleratesTrailingCarriageReturn() {
        let line = WorkQueueProtocol.encode(WorkQueueProtocol.Reply(req: 2, none: true)) + "\r"
        XCTAssertNotNil(WorkQueueProtocol.decodeReply(line))
    }

    func testIsWorkLineAcceptsOnlyTheEnvelope() {
        XCTAssertTrue(WorkQueueProtocol.isWorkLine(#"{"ftWork":{"req":1,"none":true}}"#))
        XCTAssertFalse(WorkQueueProtocol.isWorkLine(#"{"kind":"step"}"#))
        XCTAssertFalse(WorkQueueProtocol.isWorkLine(#" {"ftWork":{}}"#))
        XCTAssertFalse(WorkQueueProtocol.isWorkLine("ftWork"))
        XCTAssertFalse(WorkQueueProtocol.isWorkLine(""))
    }

    func testRejectsOtherJSONAndMismatchedShapes() {
        XCTAssertNil(WorkQueueProtocol.decodeWant(#"{"kind":"step"}"#))
        XCTAssertNil(WorkQueueProtocol.decodeReply(#"{"kind":"step"}"#))
        XCTAssertNil(WorkQueueProtocol.decodeReply("not json"))
        // want の行は返事ではない・返事の行は want ではない
        let want = WorkQueueProtocol.encode(WorkQueueProtocol.Want(req: 1, lane: "a", platform: "ios"))
        let reply = WorkQueueProtocol.encode(WorkQueueProtocol.Reply(req: 1, unit: ScenarioUnitKey(id: "A.B", variant: nil)))
        XCTAssertNil(WorkQueueProtocol.decodeReply(want))
        XCTAssertNil(WorkQueueProtocol.decodeWant(reply))
        // 中身が id も none も持たない返事は返事として読まない
        XCTAssertNil(WorkQueueProtocol.decodeReply(#"{"ftWork":{"req":1}}"#))
        XCTAssertNil(WorkQueueProtocol.decodeReply(#"{"ftWork":{"req":1,"none":false}}"#))
    }

    /// 開始・取りやめの行: 固定の形・往復・他の行と取り違えない
    func testStartAndCancelLinesRoundTripAndStayDistinct() {
        XCTAssertEqual(WorkQueueProtocol.encode(WorkQueueProtocol.StartSignal.start), #"{"ftWork":{"op":"start"}}"#)
        XCTAssertEqual(WorkQueueProtocol.decodeStartSignal(#"{"ftWork":{"op":"start"}}"# + "\r"), .start)
        let cancel = WorkQueueProtocol.encode(WorkQueueProtocol.StartSignal.cancel(reason: "beforeRun() failed"))
        XCTAssertEqual(cancel, #"{"ftWork":{"op":"cancel","reason":"beforeRun() failed"}}"#)
        XCTAssertEqual(WorkQueueProtocol.decodeStartSignal(cancel), .cancel(reason: "beforeRun() failed"))
        for other in [WorkQueueProtocol.encode(WorkQueueProtocol.Want(req: 1, lane: "a", platform: "ios")),
                      WorkQueueProtocol.encode(WorkQueueProtocol.Reply(req: 1, unit: ScenarioUnitKey(id: "A", variant: nil))),
                      WorkQueueProtocol.encode(WorkQueueProtocol.MemoHello(src: "a")),
                      #"{"kind":"step"}"#, "garbage"] {
            XCTAssertNil(WorkQueueProtocol.decodeStartSignal(other), other)
        }
        for line in [WorkQueueProtocol.encode(WorkQueueProtocol.StartSignal.start), cancel] {
            XCTAssertNil(WorkQueueProtocol.decodeWant(line))
            XCTAssertNil(WorkQueueProtocol.decodeReply(line))
            XCTAssertNil(WorkQueueProtocol.decodeMemoPiece(line))
            XCTAssertNil(WorkQueueProtocol.decodeMemoHello(line))
        }
    }

    /// 取りやめの理由は1行に収める(改行は空白へ・長さは上限で切る・空は既定の語)
    func testCancelReasonIsKeptToOneShortLine() {
        let long = String(repeating: "あ", count: 1000) + "\nsecond line"
        let line = WorkQueueProtocol.encode(WorkQueueProtocol.StartSignal.cancel(reason: long))
        XCTAssertFalse(line.contains("\n"))
        XCTAssertLessThan(line.utf8.count, 900, "ssh -tt の行規律の限度に近い")
        guard case .cancel(let reason)? = WorkQueueProtocol.decodeStartSignal(line) else { return XCTFail("取りやめに読めない") }
        XCTAssertEqual(reason.count, WorkQueueProtocol.maxCancelReasonCharacters)
        XCTAssertEqual(WorkQueueProtocol.decodeStartSignal(
            WorkQueueProtocol.encode(WorkQueueProtocol.StartSignal.cancel(reason: " \n "))), .cancel(reason: "cancelled"))
    }

    /// 文字数で切っても行のバイト数は収まらない(結合した絵文字は1字で数十バイト・制御文字は JSON で6バイトに膨らむ)。
    /// 行が `maxStartLineBytes` を超えると ssh -tt の先の子が開始の合図を受け取れずに待ち続ける
    func testCancelLineStaysWithinTheByteLimitForWideCharacters() {
        let family = "👨‍👩‍👧‍👦"  // 1つの Character・25 バイト
        for reason in [String(repeating: family, count: 300), String(repeating: "\u{1b}[31m", count: 300)] {
            let line = WorkQueueProtocol.encode(WorkQueueProtocol.StartSignal.cancel(reason: reason))
            XCTAssertLessThanOrEqual(line.utf8.count, WorkQueueProtocol.maxStartLineBytes)
            XCTAssertFalse(line.contains("\\u001b"), "制御文字を残している")
            guard case .cancel(let decoded)? = WorkQueueProtocol.decodeStartSignal(line) else { return XCTFail("取りやめに読めない") }
            XCTAssertNotEqual(decoded, "cancelled", "理由を消している(絵文字・制御文字の後の文字を残していない)")
        }
        // 書式文字(ZWJ)でつないだ絵文字は制御文字ではない = 残す
        guard case .cancel(let kept)? = WorkQueueProtocol.decodeStartSignal(
            WorkQueueProtocol.encode(WorkQueueProtocol.StartSignal.cancel(reason: "x" + family))) else { return XCTFail() }
        XCTAssertEqual(kept, "x" + family)
    }
}
