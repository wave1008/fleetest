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
        let reply = WorkQueueProtocol.Reply(req: 3, id: "Login.S0010")
        let line = WorkQueueProtocol.encode(reply)
        XCTAssertEqual(line, #"{"ftWork":{"id":"Login.S0010","req":3}}"#)
        let decoded = WorkQueueProtocol.decodeReply(line)
        XCTAssertEqual(decoded, reply)
        XCTAssertEqual(decoded?.scenarioID, "Login.S0010")
    }

    func testReplyNoneRoundTrip() {
        let reply = WorkQueueProtocol.Reply(req: 4, none: true)
        let line = WorkQueueProtocol.encode(reply)
        XCTAssertEqual(line, #"{"ftWork":{"none":true,"req":4}}"#)
        let decoded = WorkQueueProtocol.decodeReply(line)
        XCTAssertEqual(decoded, reply)
        XCTAssertNil(decoded?.scenarioID)
    }

    func testNonAsciiScenarioIDRoundTrips() {
        let reply = WorkQueueProtocol.Reply(req: 1, id: "ログイン.S0010")
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
        let reply = WorkQueueProtocol.encode(WorkQueueProtocol.Reply(req: 1, id: "A.B"))
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
                      WorkQueueProtocol.encode(WorkQueueProtocol.Reply(req: 1, id: "A")),
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
}
