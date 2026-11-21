// Android adjustResize でキーボード上端まで窓が縮み、覆われた要素が木から**消える**形
// (遮蔽ではなく脱落。実測 2026-09-05・Pixel 4a: パスワード欄フォーカスで窓 2340→1267px、
// 送信/クリアが木から脱落)。判定は KeyboardOcclusion.windowResizedAboveKeyboard の1箇所。

import XCTest
@testable import FTCore
import FTTestSupport

final class KeyboardWindowResizeTests: XCTestCase {

    private func element(ref: Int, type: String = "button", id: String? = nil,
                         x: Double, y: Double, w: Double, h: Double,
                         depth: Int = 2) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: depth)
    }

    /// 根の容器の下端がキーボード上端にちょうど一致し、はみ出す要素も無い形
    /// (実測: Pixel 4a・E2E-Android 入力画面 1267=1267)
    func testResolvesTrueWhenNothingSpillsPastTheKeyboardTop() {
        let elements = [
            element(ref: 1, type: "other", id: "root", x: 0, y: 136, w: 1080, h: 1131),
            element(ref: 2, type: "editText", x: 100, y: 400, w: 800, h: 100, depth: 3),
            element(ref: 3, type: "other", id: "tab_bar", x: 0, y: 1135, w: 360, h: 132),
        ]
        let occlusion = KeyboardOcclusion.resolve(
            reported: FTRect(x: 0, y: 1267, width: 1080, height: 1073), in: elements, screen: nil)
        XCTAssertTrue(occlusion.windowResizedAboveKeyboard,
                      "根の下端がキーボード上端に一致するのに resized と判定されなかった")
    }

    /// キーボード下へはみ出す要素(送信/クリアボタン相当)が1つでもあれば false
    /// (iOS のように窓が縮まず、覆われているだけの形)
    func testResolvesFalseWhenAnElementSpillsPastTheKeyboardTop() {
        let elements = [
            element(ref: 1, type: "other", id: "root", x: 0, y: 136, w: 1080, h: 1131),
            element(ref: 2, type: "editText", x: 100, y: 400, w: 800, h: 100, depth: 3),
            element(ref: 3, type: "other", id: "tab_bar", x: 0, y: 1135, w: 360, h: 132),
            element(ref: 4, type: "button", id: "btn_submit", x: 0, y: 1400, w: 360, h: 132),
        ]
        let occlusion = KeyboardOcclusion.resolve(
            reported: FTRect(x: 0, y: 1267, width: 1080, height: 1073), in: elements, screen: nil)
        XCTAssertFalse(occlusion.windowResizedAboveKeyboard,
                       "はみ出す要素があるのに resized と判定された")
    }

    /// 申告(keyboardFrame)が無ければ即 false(`.none` と同じ)
    func testResolvesFalseWhenThereIsNoReportedKeyboardFrame() {
        let elements = [
            element(ref: 1, type: "other", id: "root", x: 0, y: 136, w: 1080, h: 1131),
        ]
        let occlusion = KeyboardOcclusion.resolve(reported: nil, in: elements, screen: nil)
        XCTAssertFalse(occlusion.windowResizedAboveKeyboard)
        XCTAssertEqual(occlusion.frame, KeyboardOcclusion.none.frame)
    }

    // MARK: - 固定コーパスでの発火(等号で固定。増分は1件ずつ検分すること)

    /// **witness**: `and-e2e_input_keyboard_resized`(実機 Pixel 4a・keyboardFrame y=1267・
    /// 要素19件・maxBottom 1267)/ `and-form_keyboard`(1541=1541)。それ以外の keyboardFrame 持ち
    /// (`and-maps_suggest_ime` / `and-browser_urlmenu` / `ios-*`)は、木の最下端がキーボード上端を
    /// 越えて残る(はみ出す要素がある)ので false
    func testFiresOnExactlyTheKnownWindowResizeWitnesses() throws {
        let corpus = try RealAppSnapshotCorpus.all()
        let withKeyboardFrame = corpus.filter { $0.snapshot.keyboardFrame != nil }
        XCTAssertFalse(withKeyboardFrame.isEmpty, "keyboardFrame 持ちのフィクスチャが1件も無い")
        let resized = Set(withKeyboardFrame.filter {
            KeyboardOcclusion.resolve(reported: $0.snapshot.keyboardFrame,
                                      in: $0.snapshot.elements, screen: $0.snapshot.screen).windowResizedAboveKeyboard
        }.map(\.name))
        XCTAssertEqual(resized, ["and-e2e_input_keyboard_resized", "and-form_keyboard"],
                       "窓の縮みで resized と判定される画面の集合が変わった。増分を1件ずつ検分すること")
    }

    // MARK: - DSL の失敗文言(keyboardResizedHint)

    private func snapshot(elements: [ElementInfo], keyboardFrame: FTRect?) -> SnapshotResponse {
        var snap = SnapshotResponse(sessionBundleID: nil,
                                    screen: FTRect(x: 0, y: 0, width: 1080, height: 2340),
                                    elements: elements, truncatedCount: 0)
        snap.keyboardFrame = keyboardFrame
        return snap
    }

    func testKeyboardResizedHintDescribesTheShrunkWindowWithCoordinates() {
        let elements = [
            element(ref: 1, type: "other", id: "root", x: 0, y: 136, w: 1080, h: 1131),
            element(ref: 3, type: "other", id: "tab_bar", x: 0, y: 1135, w: 360, h: 132),
        ]
        let snap = snapshot(elements: elements,
                            keyboardFrame: FTRect(x: 0, y: 1267, width: 1080, height: 1073))
        let hint = StepExecutor.keyboardResizedHint(snap)
        XCTAssertTrue(hint.contains("(0,1267 1080x1073)"), "座標が実効矩形のままであること: \(hint)")
        XCTAssertTrue(hint.contains("gone from the tree"), "脱落の事実を言うこと: \(hint)")
    }

    /// 縮みと言い切れない(キーボードの下へはみ出す要素がある)ときは、座標つきの「消えた」を言わず、
    /// キーボードが出ている事実だけで「縮む作りなら消えうる・先に閉じる」を添える(MCP の hiddenOrOffscreenHint と同じ判定)
    func testKeyboardResizedHintIsSoftWhenTheWindowHasNotResized() {
        let elements = [
            element(ref: 1, type: "other", id: "root", x: 0, y: 136, w: 1080, h: 1131),
            element(ref: 4, type: "button", id: "btn_submit", x: 0, y: 1400, w: 360, h: 132),
        ]
        let snap = snapshot(elements: elements,
                            keyboardFrame: FTRect(x: 0, y: 1267, width: 1080, height: 1073))
        let hint = StepExecutor.keyboardResizedHint(snap)
        XCTAssertTrue(hint.contains("hideKeyboard()"), hint)
        XCTAssertFalse(hint.contains("gone from the tree"), "縮みと言い切っている: \(hint)")
    }

    /// 実測(11/22・Sim・E2E-CMP の入力画面で複数行の欄に打った直後の XCUITest の木): CMP の全画面の容器
    /// `scrollView (0,0 402x874)` が下端まで残るので幾何の判定は立たない(in-app の木では最下端 538 = キーボードの上端で立つ)。
    /// それでも DSL の not found に閉じる手を添える
    func testKeyboardHintIsGivenForTheXCUITestTreeOfComposeMultiplatform() {
        var snap = SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                    elements: [
                                        element(ref: 1, type: "scrollView", x: 0, y: 0, w: 402, h: 874, depth: 1),
                                        element(ref: 17, id: "tab_home", x: 0, y: 490, w: 134, h: 48),
                                        element(ref: 23, type: "other", id: "inputView", x: 0, y: 538, w: 402, h: 336),
                                    ], truncatedCount: 0)
        snap.keyboardFrame = FTRect(x: 0, y: 583, width: 402, height: 233)
        XCTAssertFalse(KeyboardOcclusion.resolve(reported: snap.keyboardFrame, in: snap.elements, screen: snap.screen)
                        .windowResizedAboveKeyboard, "前提: XCUITest の木では縮みの判定が立たない")
        XCTAssertTrue(StepExecutor.keyboardResizedHint(snap).contains("hideKeyboard()"))
    }

    func testKeyboardHintIsEmptyWhenTheKeyboardIsNotShown() {
        let elements = [element(ref: 1, type: "other", id: "root", x: 0, y: 136, w: 1080, h: 1131)]
        XCTAssertEqual(StepExecutor.keyboardResizedHint(snapshot(elements: elements, keyboardFrame: nil)), "")
    }

    func testKeyboardResizedHintIsEmptyWithoutASnapshot() {
        XCTAssertEqual(StepExecutor.keyboardResizedHint(nil), "")
    }
}
