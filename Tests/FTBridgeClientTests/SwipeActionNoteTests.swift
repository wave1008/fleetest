// 送り(`/swipe`)の応答で `lastActionNote` を書き直すこと。書かないと送りの直後に読む `StepExecutor.consumeSwipeBridgeNote` が
// 前の tap の注記を読み、送りのステップに起きていない事実(「activate did not fire -> synthetic touch」)を残す
// (RN の inapp-boost で scrollDown の全ステップに付いた)。HTTP を立てずにソースで押さえる(OpenURLRestoreNoteAndObservationTests と同じ形)
import XCTest

final class SwipeActionNoteTests: XCTestCase {
    func testSwipeOverwritesTheActionNoteWithItsOwnResponse() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FTBridgeClient/BridgeClient.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let start = source.range(of: "public func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent,"),
              let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex) else {
            return XCTFail("BridgeClient.swipe(_:intent:path:) が見つからない")
        }
        let body = source[start.lowerBound..<end.upperBound]
        XCTAssertTrue(body.contains("lastActionNote = response.note"),
                      "送りの応答で lastActionNote を書き直していない(前の tap の注記が送りのステップに残る)")
    }
}
