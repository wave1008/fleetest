// 子の stdout の行は、既知のイベントの種類のときだけイベントとして読む(`ScenarioEvent.decodeChildLine`)。
// 利用者の print は同じ stdout に出るので、"kind" を持つ JSON(API の応答等)をイベントと読むとログから消え、
// 種類によっては合否まで上書きする

import XCTest
@testable import FTCore

final class ScenarioEventChildKindsTests: XCTestCase {
    /// 利用者が print した API の応答(`"kind"` 欄を持つ JSON)はイベントにしない = 呼び手がログ行として出す
    func testUserPrintedJSONWithAKindFieldIsNotAnEvent() {
        XCTAssertNil(ScenarioEvent.decodeChildLine(#"{"kind":"youtube#video","id":"abc"}"#))
        XCTAssertNil(ScenarioEvent.decodeChildLine(#"{"kind":"result","passed":true}"#))
    }

    func testKnownChildEventsAreStillEvents() {
        XCTAssertEqual(ScenarioEvent.decodeChildLine(#"{"kind":"log","message":"hi"}"#)?.kind, "log")
        XCTAssertEqual(ScenarioEvent.decodeChildLine(ScenarioEvent(kind: "scenarioFinished").encodedLine())?.kind,
                       "scenarioFinished")
    }

    /// ソース中で作られるイベントの種類は全部 `knownKinds` に載っている(足し忘れるとそのイベントは生の JSON のログ行に化ける)
    func testEveryKindConstructedInSourcesIsKnown() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let pattern = try NSRegularExpression(pattern: #"ScenarioEvent\(\s*kind:\s*"([A-Za-z]+)""#)
        var found: Set<String> = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) { found.insert(String(text[range])) }
            }
        }
        XCTAssertGreaterThanOrEqual(found.count, 15, "走査が ScenarioEvent(kind:) に届いていない")
        XCTAssertEqual(found.subtracting(ScenarioEvent.knownKinds), [], "knownKinds に載っていない種類")
    }
}
