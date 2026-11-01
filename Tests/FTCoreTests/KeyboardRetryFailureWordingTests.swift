// 見つからない対象の tap / type / clearInput がキーボードを閉じて探し直した後の失敗文(emu F6・se3 F1)。
// 閉じた後なのに「Close it first (hideKeyboard())」と言う・閉じられなかった理由を捨てる、を落とす。
// あわせて iOS の hideKeyboard の Enter が欄の値を変えたかの判定(se3 F2)と、横向きの申告枠が画面に収まらない形(mu F4)。

import XCTest
@testable import FTCore

final class KeyboardRetryFailureWordingTests: XCTestCase {
    private let city = ElementInfo(ref: 1, type: "textField", identifier: "field_city", label: nil, value: nil,
                                   placeholder: nil, enabled: true, frame: FTRect(x: 20, y: 400, width: 360, height: 50),
                                   depth: 1)

    private func run(closes: Bool) async -> (String, [String]) {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[city]])
        primary.keyboardFrame = FTRect(x: 0, y: 450, width: 400, height: 350)
        if closes {
            primary.afterHideKeyboard = {
                primary.keyboardFrame = nil
                primary.keyboardShownFrames = [false]
            }
        }
        let executor = StepExecutor(driver: primary, isAndroid: true, tunables: RunTunables(defaultTimeout: 0.2))
        let outcome = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "no_such")))
        guard case .failed(let message) = outcome.status else { return ("not failed: \(outcome.status)", log.entries) }
        return (message, log.entries)
    }

    /// 閉じてから探し直しても無かった: 閉じた事実を言い、「閉じろ」と言わない
    func testFailureAfterClosingSaysItClosedAndDoesNotAskToCloseIt() async {
        let (message, entries) = await run(closes: true)
        XCTAssertEqual(entries.filter { $0 == "primary.hideKeyboard" }.count, 1, entries.description)
        XCTAssertTrue(message.contains("the soft keyboard was up: closed the keyboard (back key)"), message)
        XCTAssertFalse(message.contains("Close it first"), message)
    }

    /// 閉じられなかった: 試したことを失敗文に残す(捨てて「cannot resolve」だけにしない)
    func testFailureWhenTheKeyboardWillNotCloseNamesWhatWasTried() async {
        let (message, _) = await run(closes: false)
        XCTAssertTrue(message.contains("closing it without side effects failed"), message)
        XCTAssertTrue(message.contains("did not close it"), message)
    }

    private func field(value: String?) -> ElementInfo {
        ElementInfo(ref: 1, type: "textView", identifier: "field_multiline", label: nil, value: value, placeholder: nil,
                    enabled: true, frame: FTRect(x: 16, y: 148, width: 370, height: 100), depth: 1, focused: true)
    }

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 402, height: 874), elements: elements,
                         truncatedCount: 0)
    }

    /// Enter が焦点の欄の値を変えた(複数行 = 改行が入る)ときだけ true。変わらない・欄が無いときは言わない
    func testFocusedValueChangedDetectsTheNewline() {
        XCTAssertTrue(StepExecutor.focusedValueChanged(before: field(value: "x"), after: snapshot([field(value: "x\n")])))
        XCTAssertFalse(StepExecutor.focusedValueChanged(before: field(value: "x"), after: snapshot([field(value: "x")])))
        XCTAssertFalse(StepExecutor.focusedValueChanged(before: nil, after: snapshot([field(value: "x\n")])))
        XCTAssertFalse(StepExecutor.focusedValueChanged(before: field(value: "x"), after: snapshot([])))
    }

    /// 横向きの XCUITest が縦の座標系のまま申告する枠(694x694・画面は 844x390)は、木の inputView の枠に替える。
    /// 縦の座標系の chrome(SystemInputAssistantView 44x694)で実効矩形を広げない(広げると見えている欄を「キーボードの下」と断る)
    func testLandscapeImplausibleReportedFrameFallsBackToInputView() {
        func el(_ ref: Int, _ id: String, _ frame: FTRect) -> ElementInfo {
            ElementInfo(ref: ref, type: "other", identifier: id, label: nil, value: nil, placeholder: nil, enabled: true,
                        frame: frame, depth: 1)
        }
        let screen = FTRect(x: 0, y: 0, width: 844, height: 390)
        let tab = ElementInfo(ref: 3, type: "button", identifier: "tab_controls", label: nil, value: nil, placeholder: nil,
                              enabled: true, frame: FTRect(x: 297, y: 134, width: 250, height: 48), depth: 1)
        let tree = [el(1, "inputView", FTRect(x: 75, y: 182, width: 694, height: 208)),
                    el(2, "SystemInputAssistantView", FTRect(x: 164, y: 75, width: 44, height: 694)), tab]
        let occlusion = KeyboardOcclusion.resolve(reported: FTRect(x: 75, y: 75, width: 694, height: 694), in: tree,
                                                  screen: screen)
        XCTAssertEqual(occlusion.frame?.y, 182)
        XCTAssertEqual(occlusion.frame?.height, 208)
        XCTAssertNil(occlusion.advisory(for: tab), "見えている tab を「キーボードの下」と言った")
        // 収まる申告は従来どおり
        let normal = KeyboardOcclusion.resolve(reported: FTRect(x: 75, y: 182, width: 694, height: 208), in: tree, screen: screen)
        XCTAssertEqual(normal.frame?.y, 182)
    }

    /// 横向きは切り欠きの帯の点でなく中身の横の範囲の点を先に選ぶ(iOS 横向きの CMP が毎回左端 (18,y) を選んで閉じなかった)
    func testLandscapeDismissPointStaysInsideTheContent() throws {
        let screen = FTRect(x: 0, y: 0, width: 874, height: 402)
        let keyboard = FTRect(x: 75, y: 190, width: 724, height: 212)
        let root = ElementInfo(ref: 1, type: "other", identifier: nil, label: nil, value: nil, placeholder: nil, enabled: true,
                               frame: screen, depth: 0)
        func text(_ ref: Int, _ x: Double) -> ElementInfo {
            ElementInfo(ref: ref, type: "staticText", identifier: nil, label: "t", value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: x, y: 10, width: 100, height: 30), depth: 1)
        }
        let found = KeyboardDismissPoint.candidates(elements: [root, text(2, 100), text(3, 696)], screen: screen,
                                                    keyboard: keyboard, overlays: [])
        let first = try XCTUnwrap(found.first)
        XCTAssertGreaterThanOrEqual(first.x, 100)
        XCTAssertLessThanOrEqual(first.x, 796)
    }
}
