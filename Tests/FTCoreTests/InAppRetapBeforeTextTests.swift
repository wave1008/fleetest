// OI-162: iOS の in-app で tap した欄へ type / clearInput すると欄をもう一度叩き、CMP は焦点のある欄の
// 2度目のタップで編集メニュー(Select All)を出して残す。直前の tap が焦点を立てた欄は叩き直さない。
// in-app の dylib は swift test でリンクされないので、配線はソースを走査して守る。

import XCTest
import FTCore

final class InAppRetapBeforeTextTests: XCTestCase {

    func testSkipsOnlyWhenPriorTapLandedAndAReceiverExists() {
        XCTAssertTrue(FocusLanding.skipsRetapBeforeText(priorTapLanded: true, receiverPresent: true))
        // 焦点を立てた tap が無い(別の欄・焦点無し)= 叩いて焦点を取る
        XCTAssertFalse(FocusLanding.skipsRetapBeforeText(priorTapLanded: false, receiverPresent: true))
        XCTAssertFalse(FocusLanding.skipsRetapBeforeText(priorTapLanded: false, receiverPresent: false))
        // キーボードが閉じて受け口が無い = 叩き直して焦点を取り直す
        XCTAssertFalse(FocusLanding.skipsRetapBeforeText(priorTapLanded: true, receiverPresent: false))
    }

    func testTypeAndClearGateTheSyntheticTapOnTheDecision() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bridge = try String(contentsOf: root.appendingPathComponent("InAppBridge/Sources/InAppBridge.swift"),
                                encoding: .utf8)
        for (name, next) in [("private func handleType(", "private func handleClear("),
                             ("private func handleClear(", "private static func splitTrailingNewline(")] {
            guard let start = bridge.range(of: name),
                  let end = bridge.range(of: next, range: start.upperBound..<bridge.endIndex)
            else { return XCTFail("\(name) の範囲が見つかりません") }
            let body = bridge[start.upperBound..<end.lowerBound]
            let gate = body.range(of: "FocusLanding.skipsRetapBeforeText(")
            let tap = body.range(of: "FTSynthTap(window, point)")
            XCTAssertNotNil(gate, "\(name) は叩き直しの判定を通る")
            XCTAssertNotNil(tap)
            if let gate, let tap { XCTAssertLessThan(gate.lowerBound, tap.lowerBound, "\(name) の FTSynthTap は判定の後ろ") }
        }
    }
}
