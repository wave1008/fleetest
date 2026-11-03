// iOS の in-app で tap した欄へ type / clearInput すると欄をもう一度叩き、CMP は焦点のある欄の
// 2度目のタップで編集メニュー(Select All)を出して残す。直前の tap が焦点を立てた欄は叩き直さない。
// in-app の dylib は swift test でリンクされないので、配線はソースを走査して守る。

import XCTest
@testable import FTCore

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
            // 焦点のタップの点はキーボードを避ける(中心のままキーを押して焦点の別の欄へ打鍵が入った。OI-163 ①)
            XCTAssertTrue(body.contains("point = try self.focusTapPointOffKeyboard(ref: ref, centre: point)\n                    FTSynthTap(window, point)"),
                          "\(name) の焦点のタップがキーボードを避けていない")
        }
    }

    /// 焦点を動かしうる要求(pressEnter 等)を挟んだら記録を捨てる(探索: tap(姓) → pressEnter → clearInput(姓) が叩き直さずに
    /// 名を消して ok)。読むだけ・記録を作る tap・記録を使う type / clear は残す
    func testPriorTapRecordIsKeptOnlyAcrossReadsAndTheTextRequests() {
        for (method, path) in [("GET", "/snapshot"), ("GET", "/status"), ("POST", "/tap"), ("POST", "/type"), ("POST", "/clear")] {
            XCTAssertTrue(FocusLanding.keepsPriorTapRecord(method: method, path: path), path)
        }
        for path in ["/pressEnter", "/hidekeyboard", "/swipe", "/drag", "/press", "/doubletap", "/rotate", "/tapprobe", "/pinch"] {
            XCTAssertFalse(FocusLanding.keepsPriorTapRecord(method: "POST", path: path), path)
        }
    }

    /// 配線: 要求の入口で判定し、ref の無い type / clear も記録を捨てる
    func testRouterAndRefLessTextRequestsDropTheRecord() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bridge = try String(contentsOf: root.appendingPathComponent("InAppBridge/Sources/InAppBridge.swift"),
                                encoding: .utf8)
        XCTAssertTrue(bridge.contains("if !FocusLanding.keepsPriorTapRecord(method: req.method, path: req.path) { lastRefTap = nil }"))
        XCTAssertEqual(bridge.components(separatedBy: "if req.ref == nil { lastRefTap = nil }").count - 1, 2)
    }

    /// XCUITest ランナーの type / clear は、焦点を当てるタップの点が撮り直した木のキーボードの上なら撃たずに断る
    /// (inapp-boost モードの CMP の clearInput はランナーを通る。キーを押して焦点のある別の欄を書き換えた。OI-163 ①)
    func testRunnerFocusTapsCheckTheKeyboardFirst() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let runner = try String(contentsOf: root.appendingPathComponent("Runner/FleetestRunnerUITests/BridgeRouter+TextInput.swift"),
                                encoding: .utf8)
        let guarded = "let point = try focusTapPointOffKeyboard(ref: ref, centre: try resolvePoint(ref: ref, x: nil, y: nil), fresh: fresh)\n"
        XCTAssertEqual(runner.components(separatedBy: guarded + "            Self.tapBeforeTyping(coordinate(app, point))").count - 1, 1, "type")
        XCTAssertEqual(runner.components(separatedBy: guarded + "                let focusBefore = Self.focusMark(app)\n"
            + "                Self.tapBeforeTyping(coordinate(app, point))").count - 1, 1, "clear")
    }

    /// XCUITest で消す前に、撮り直した欄の位置を主ドライバ(in-app)のキーボードの枠と突き合わせる(XCTest の枠は焦点が移る間
    /// 画面の外で来る)。焦点のある欄・画面の外の枠・覆われていない欄は撃ってよい
    func testHostRefusesTypeDriverClearUnderTheWitnessKeyboard() {
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        let kb = FTRect(x: 0, y: 538, width: 402, height: 336)
        var field = ElementInfo(ref: 18, type: "textView", identifier: "field_first", label: "姓", value: "AB",
                                placeholder: nil, enabled: true, frame: FTRect(x: 16, y: 608, width: 370, height: 64), depth: 3)
        XCTAssertNotNil(StepExecutor.focusTapUnderKeyboard(field, keyboardWitness: kb, screen: screen))
        XCTAssertNil(StepExecutor.focusTapUnderKeyboard(field, keyboardWitness: nil, screen: screen))
        XCTAssertNil(StepExecutor.focusTapUnderKeyboard(field, keyboardWitness: FTRect(x: 0, y: 891, width: 402, height: 233),
                                                        screen: screen), "画面の外の枠はキーボード無し")
        field.focused = true
        XCTAssertNil(StepExecutor.focusTapUnderKeyboard(field, keyboardWitness: kb, screen: screen), "焦点の欄は叩かずに消す")
        field.focused = nil
        field.frame = FTRect(x: 16, y: 450, width: 370, height: 64)
        XCTAssertNil(StepExecutor.focusTapUnderKeyboard(field, keyboardWitness: kb, screen: screen))
    }
}
