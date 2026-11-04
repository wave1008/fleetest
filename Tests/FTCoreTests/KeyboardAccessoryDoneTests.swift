// iOS の WebView の欄でキーボードを出すと、ページに空きの点が無く hideKeyboard が閉じる手段を失って Enter まで送っていた。
// 木に載っている OS の入力補助バー(型 toolbar・識別子 Toolbar)の Done を、空きが無いときに押す。アプリ独自のバーは押さない。

import XCTest
@testable import FTCore

final class KeyboardAccessoryDoneTests: XCTestCase {
    private let keyboard = FTRect(x: 0, y: 538, width: 402, height: 336)

    private func element(_ ref: Int, _ type: String, id: String? = nil, label: String? = nil, depth: Int,
                         _ x: Double, _ y: Double, _ w: Double, _ h: Double, enabled: Bool = true) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil, placeholder: nil, enabled: enabled,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: depth)
    }

    /// 実測の木(iPhone 17 Pro・E2E-iOS の WebView の欄): Toolbar の下に Previous / Next(無効)/ Done
    private func osToolbar(id: String? = "Toolbar", nextEnabled: Bool = false) -> [ElementInfo] {
        [element(22, "toolbar", id: id, label: "Toolbar", depth: 4, 0, 480, 402, 48),
         element(23, "button", label: "Previous", depth: 5, 21, 485, 40, 38, enabled: nextEnabled),
         element(24, "button", label: "Next", depth: 5, 75, 485, 40, 38, enabled: nextEnabled),
         element(25, "button", label: "Done", depth: 5, 341, 485, 40, 38)]
    }

    func testPicksTheLastEnabledButtonOfTheOSToolbarAboveTheKeyboard() throws {
        let done = try XCTUnwrap(KeyboardAccessoryDone.target(in: osToolbar(), keyboard: keyboard))
        XCTAssertEqual(done.ref, 25)
        // 欄が複数ある形(Previous / Next が有効)でも最後が Done
        let multi = try XCTUnwrap(KeyboardAccessoryDone.target(in: osToolbar(nextEnabled: true), keyboard: keyboard))
        XCTAssertEqual(multi.ref, 25)
    }

    /// アプリ独自のバーの最後のボタンは「送信」かもしれない: OS の識別子でなければ押さない
    func testAnAppsOwnToolbarIsNotTouched() {
        XCTAssertNil(KeyboardAccessoryDone.target(in: osToolbar(id: "chat_toolbar"), keyboard: keyboard))
        XCTAssertNil(KeyboardAccessoryDone.target(in: osToolbar(id: nil), keyboard: keyboard))
    }

    /// 実測: 予測変換の帯を挟むとバーの下端とキー面の上端の間が 55pt 空く
    func testAPredictionBarBetweenTheToolbarAndTheKeysIsAllowed() {
        let keys = FTRect(x: 0, y: 583, width: 402, height: 233)
        XCTAssertEqual(KeyboardAccessoryDone.target(in: osToolbar(), keyboard: keys)?.ref, 25)
    }

    /// キーボードの上に付いていないバー(画面の上の方のツールバー)は対象外
    func testAToolbarFarFromTheKeyboardIsNotTouched() {
        let far = osToolbar().map { element -> ElementInfo in
            var moved = element
            moved.frame.y -= 300
            return moved
        }
        XCTAssertNil(KeyboardAccessoryDone.target(in: far, keyboard: keyboard))
    }

    func testNoToolbarMeansNoTarget() {
        XCTAssertNil(KeyboardAccessoryDone.target(in: [element(1, "button", label: "Done", depth: 1, 0, 0, 40, 40)],
                                                  keyboard: keyboard))
    }

    /// 本命: ページ全体が押せる部品で埋まり空きの点が無い WebView の形で、Enter を送らず Done を押して閉じる
    func testHideKeyboardTapsDoneInsteadOfSendingEnterWhenThereIsNoEmptySpot() async {
        let log = CallLog()
        let page = element(1, "button", label: "page", depth: 1, 0, 0, 402, 538)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[page] + osToolbar()])
        primary.keyboardFrame = keyboard
        primary.afterCoordinateTap = {
            primary.keyboardFrame = nil
            primary.keyboardShownFrames = [false]
        }
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables(defaultTimeout: 0.5))

        let outcome = await executor.execute(FlowStep(action: "hideKeyboard"))

        XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "\(outcome.status)")
        XCTAssertEqual(primary.coordinateTaps.count, 1, "Done を1回だけ押す: \(primary.coordinateTaps)")
        XCTAssertEqual(primary.coordinateTaps.first?.x, 361)
        XCTAssertEqual(primary.coordinateTaps.first?.y, 504)
        XCTAssertFalse(log.entries.contains { $0.contains("pressEnter") }, "Enter を送っている: \(log.entries)")
        XCTAssertTrue(outcome.driverFallback?.contains("Done button of its toolbar") == true, outcome.driverFallback ?? "nil")
    }

    /// inapp-boost モード: バーは主ドライバの木に載らないので、XCUITest の木で見つけて XCUITest で押す
    func testInAppPrimaryFindsDoneInTheXCUITestTreeAndTapsItThere() async {
        let log = CallLog()
        let page = element(1, "button", label: "page", depth: 1, 0, 0, 402, 538)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[page]])
        primary.keyboardFrame = keyboard
        let xcuitest = FakeAppDriver(name: "xcuitest", log: log, snapshotElements: [[page] + osToolbar()])
        xcuitest.keyboardFrame = keyboard
        xcuitest.afterCoordinateTap = {
            primary.keyboardFrame = nil
            primary.keyboardShownFrames = [false]
        }
        let executor = StepExecutor(driver: primary, typeDriver: xcuitest, isAndroid: false, tunables: RunTunables(defaultTimeout: 0.5))

        let outcome = await executor.execute(FlowStep(action: "hideKeyboard"))

        XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "\(outcome.status)")
        XCTAssertEqual(xcuitest.coordinateTaps.first?.x, 361)
        XCTAssertTrue(primary.coordinateTaps.isEmpty, "主ドライバで撃っている: \(primary.coordinateTaps)")
        XCTAssertFalse(log.entries.contains { $0.contains("pressEnter") }, "Enter を送っている: \(log.entries)")
    }
}
