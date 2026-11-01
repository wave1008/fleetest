// 撃つ前の入口(PreFireGuard)の判定と、操作 × 経路の表(空の升で落ちる)

import XCTest
@testable import FTCore

final class PreFireGuardTests: XCTestCase {
    private func e(_ ref: Int, _ id: String, _ f: FTRect) -> ElementInfo {
        ElementInfo(ref: ref, type: "button", identifier: id, label: id, value: nil, placeholder: nil, enabled: true,
                    frame: f, depth: 2)
    }

    private let screen = FTRect(x: 0, y: 0, width: 360, height: 760)
    private let keyboard = FTRect(x: 0, y: 500, width: 360, height: 260)

    private func tree(_ elements: [ElementInfo], keyboardShown: Bool) -> SnapshotResponse {
        var s = SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements, truncatedCount: 0)
        if keyboardShown { s.keyboardFrame = keyboard }
        return s
    }

    func testKeyboardCoverNeedsAShownKeyboard() {
        let button = e(1, "btn_clear", FTRect(x: 20, y: 440, width: 150, height: 60))
        let bar = e(2, "tab_controls", FTRect(x: 0, y: 440, width: 360, height: 60))
        let shown = tree([button, bar], keyboardShown: true)
        let occlusion = KeyboardOcclusion.resolve(reported: shown.keyboardFrame, in: shown.elements, screen: screen)
        guard case .raisedBar(let over)? = PreFireGuard.keyboardCover(of: button, in: shown, keyboard: occlusion) else {
            return XCTFail("せり上がったバーを拾えていない")
        }
        XCTAssertEqual(over.identifier, bar.identifier)
        let hidden = tree([button, bar], keyboardShown: false)
        let none = KeyboardOcclusion.resolve(reported: nil, in: hidden.elements, screen: screen)
        XCTAssertNil(PreFireGuard.keyboardCover(of: button, in: hidden, keyboard: none))
        let thin = e(3, "btn_send", FTRect(x: 199, y: 410, width: 175, height: 2))
        guard case .collapsed? = PreFireGuard.keyboardCover(of: thin, in: shown, keyboard: occlusion) else {
            return XCTFail("潰れた枠を拾えていない")
        }
    }

    func testRefLessInputIsOnlyTheLocatorlessInputSteps() {
        XCTAssertEqual(PreFireGuard.refLessInput(FlowStep(action: "type")), .typing)
        XCTAssertEqual(PreFireGuard.refLessInput(FlowStep(action: "clearInput")), .clearing)
        XCTAssertEqual(PreFireGuard.refLessInput(FlowStep(action: "pressEnter")), .pressingEnter)
        XCTAssertNil(PreFireGuard.refLessInput(FlowStep(action: "tap")))
        XCTAssertNil(PreFireGuard.refLessInput(FlowStep(action: "type", locator: FlowLocator(id: "field"))))
        XCTAssertNil(PreFireGuard.refLessInputRefusal(what: "typing", frontWarning: ""))
        XCTAssertTrue(PreFireGuard.refLessInputRefusal(what: "typing", frontWarning: " (warning: x)")?
            .contains("nothing was sent") == true)
    }

    /// **操作 × 撃つ前の入口** の表。指で要素を触る操作が入口に載っていないと落ちる
    func testEveryElementTouchActionPassesTheEntrance() {
        var longPress = FlowStep(action: "tap")
        longPress.duration = 0.8
        let table: [(name: String, step: FlowStep, enters: Bool)] = [
            ("doubleTap", FlowStep(action: "doubleTap"), true),
            ("swipeElementToElement", FlowStep(action: "swipeElementToElement"), true),
            ("holdStart", FlowStep(action: "holdStart"), true),
            ("tap + hold", longPress, true),
            // 押すだけの tap は自前の経路が同じ部品を通る
            ("tap", FlowStep(action: "tap"), false),
            // 容器の枠はキーボードの下まで伸びるのが通常 = 注記のみ
            ("swipeBy", FlowStep(action: "swipeBy"), false),
            ("pinchOut", FlowStep(action: "pinchOut"), false),
            ("gesture", FlowStep(action: "gesture"), false),
            // 自前の経路(lift → reachPastKeyboard)
            ("type", FlowStep(action: "type"), false),
            ("clearInput", FlowStep(action: "clearInput"), false),
        ]
        for row in table {
            XCTAssertEqual(StepExecutor.reachesTargetBeforeTouch(action: row.step.action ?? "", step: row.step),
                           row.enters, row.name)
        }
        XCTAssertEqual(PreFireGuard.elementTouchActions, ["doubleTap", "swipeElementToElement", "holdStart"])
    }

    /// 入口を呼ぶのは Actions の1箇所(要素の操作の switch の前)。case ごとの個別の呼び出しを足さない
    func testEntranceIsCalledOnceBeforeTheActionSwitch() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/StepExecutor+Actions.swift"),
                                encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        XCTAssertEqual(source.components(separatedBy: "reachBeforeTouch(").count - 1, 1)
        let entrance = try XCTUnwrap(source.range(of: "reachBeforeTouch("))
        let switchRange = try XCTUnwrap(source.range(of: "switch action {\n        case \"select\":"))
        XCTAssertLessThan(entrance.lowerBound, switchRange.lowerBound)
        XCTAssertFalse(source.contains("TapTargetGeometry.isCollapsedFrame"),
                       "潰れた枠・せり上がったバーの判定は PreFireGuard.keyboardCover の1箇所")
    }
}
