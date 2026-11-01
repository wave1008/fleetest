// 操作 × 撃つ前の入口の表(空の升で落ちる)と、送る先の無い覆い・貼り付く見出し・注記の操作名

import XCTest
@testable import FTCore

final class StepActionCoverageTests: XCTestCase {
    private func e(_ ref: Int, _ id: String, _ f: FTRect, type: String = "button", depth: Int = 2) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: id, value: nil, placeholder: nil, enabled: true,
                    frame: f, depth: depth)
    }

    private let screen = FTRect(x: 0, y: 0, width: 360, height: 760)
    private let keyboard = FTRect(x: 0, y: 500, width: 360, height: 260)

    /// **操作 × 撃つ前の入口** の表。`StepAction` の全 case が表に載っていないと落ちる
    func testEveryStepActionHasAnEntranceRow() {
        var longPress = FlowStep(action: "tap")
        longPress.duration = 0.8
        let button = e(1, "btn", FTRect(x: 20, y: 440, width: 150, height: 60))
        let surface = e(2, "list", FTRect(x: 0, y: 0, width: 360, height: 700), type: "scrollView", depth: 1)
        // action → (小さな要素, 大きな面)
        let table: [StepAction: (button: StepExecutor.EntrancePlan, surface: StepExecutor.EntrancePlan)] = [
            .doubleTap: (.full, .full), .holdStart: (.full, .full), .swipeElementToElement: (.full, .full),
            // 払いは画面内で切られる大きな面は通さない(緑を赤にしない)
            .swipeBy: (.full, .skip),
            .pinchOut: (.full, .withoutLift), .pinchIn: (.full, .withoutLift), .gesture: (.full, .withoutLift),
            .tap: (.skip, .skip), .type: (.skip, .skip), .clearInput: (.skip, .skip),
            .findImage: (.skip, .skip), .findImages: (.skip, .skip), .existImage: (.skip, .skip),
            .swipe: (.skip, .skip), .scroll: (.skip, .skip), .scrollToEdge: (.skip, .skip), .flick: (.skip, .skip),
            .scrollTo: (.skip, .skip), .swipePointToPoint: (.skip, .skip), .fold: (.skip, .skip),
            .unfold: (.skip, .skip), .hinge: (.skip, .skip), .rotateTo: (.skip, .skip), .pressEnter: (.skip, .skip),
            .hideKeyboard: (.skip, .skip), .holdEnd: (.skip, .skip), .waitForSettle: (.skip, .skip),
            .select: (.skip, .skip),
        ]
        for action in StepAction.allCases {
            guard let row = table[action] else { XCTFail("\(action) が経路の表に無い"); continue }
            let step = FlowStep(action: action.rawValue)
            XCTAssertEqual(StepExecutor.entrancePlan(action: action.rawValue, step: step, element: button, screen: screen),
                           row.button, "\(action) 小さな要素")
            XCTAssertEqual(StepExecutor.entrancePlan(action: action.rawValue, step: step, element: surface, screen: screen),
                           row.surface, "\(action) 大きな面")
        }
        XCTAssertEqual(StepExecutor.entrancePlan(action: "tap", step: longPress, element: button, screen: screen), .full)
        XCTAssertEqual(StepExecutor.entrancePlan(action: "unknown", step: FlowStep(action: "unknown"), element: button,
                                                 screen: screen), .skip)
        XCTAssertEqual(PreFireGuard.elementTouchActions,
                       ["doubleTap", "swipeElementToElement", "holdStart", "swipeBy", "pinchOut", "pinchIn", "gesture"])
        XCTAssertEqual(PreFireGuard.keyboardSensitiveActions,
                       PreFireGuard.elementTouchActions.union(["tap", "type", "clearInput"]))
    }

    /// executor の action の switch / 比較に出る文字列は全部 `StepAction` にある(新しい操作は分類を決めないと通らない)
    func testExecutorActionLiteralsAreAllClassified() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var literals = Set<String>()
        let literal = try NSRegularExpression(pattern: "\"(\\w+)\"")
        let comparison = try NSRegularExpression(pattern: "\\baction [!=]= \"(\\w+)\"")
        func collect(_ regex: NSRegularExpression, in text: String) {
            for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(m.range(at: 1), in: text) { literals.insert(String(text[r])) }
            }
        }
        for name in ["Actions", "DirectActions", "Hold", "PreTouch", "TypeClear", "FindImage"] {
            let text = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/StepExecutor+\(name).swift"),
                                  encoding: .utf8)
            for line in text.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("//") { continue }
                collect(comparison, in: t)
                // switch action の case(Actions.swift の本体と performGesture は 8 桁字下げ)
                if name == "Actions", line.hasPrefix("        case \""), t.hasSuffix(":") { collect(literal, in: t) }
            }
        }
        let known = Set(StepAction.allCases.map(\.rawValue))
        XCTAssertGreaterThan(literals.count, 15, "走査が action に届いていない")
        XCTAssertEqual(literals.subtracting(known), [], "StepAction に無い action がある。touchClass を決めて足す")
    }

    func testKeyboardAdvisoryNamesTheOperation() {
        let button = e(1, "btn", FTRect(x: 20, y: 600, width: 150, height: 60))
        let note = TapTargetGeometry.keyboardCoveredAdvisory(button, keyboardFrame: keyboard,
                                                             operation: StepAction.touchNoun(for: "pinchOut"))
        XCTAssertTrue(note?.contains("the pinch will land") == true)
        XCTAssertTrue(TapTargetGeometry.keyboardCoveredAdvisory(button, keyboardFrame: keyboard)?
            .contains("the tap will land") == true)
    }

    /// 貼り付く見出しが木で容器の直前に並んでも、祖先と読まれず帯として拾われる
    func testPinnedBandIsNotMisreadAsAncestorWhenItPrecedesTheContainer() {
        let container = FTRect(x: 0, y: 160, width: 360, height: 500)
        let header = e(1, "hdr_E", FTRect(x: 16, y: 180, width: 83, height: 20), type: "staticText", depth: 9)
        var scroller = e(2, "list", container, type: "scrollView", depth: 10)
        scroller.scrollable = true
        let row = e(3, "row_s_E3", FTRect(x: 0, y: 170, width: 360, height: 40), type: "other", depth: 11)
        let tree = [header, scroller, row]
        XCTAssertEqual(TapTargetGeometry.pinnedBandCovering(row, in: tree, container: container)?.identifier, "hdr_E")
        XCTAssertNotNil(TapTargetGeometry.pinnedBandNote(for: row, in: tree, operation: "touch"))
        // 本物の祖先(枠が対象を含む)は覆いに数えない
        let parent = e(4, "hdr_P", FTRect(x: 0, y: 160, width: 360, height: 60), type: "other", depth: 9)
        let child = e(5, "child", FTRect(x: 10, y: 170, width: 100, height: 30), type: "staticText", depth: 10)
        XCTAssertNil(TapTargetGeometry.pinnedBandCovering(child, in: [parent, child], container: container))
    }

    /// キーボード表示中の枠なし払いは、キーボードの上に残った領域の中心を含む最大の scrollable を容器にする
    /// (画面全体だと始点が一覧の外の固定ヘッダに落ちて動かない。反転チャットの一覧は (0,485) から始まる)
    func testKeyboardScrollContainerPicksTheListNotTheWholeScreen() {
        let screenRect = FTRect(x: 0, y: 0, width: 1080, height: 2400)
        let list = ElementInfo(ref: 1, type: "scrollView", identifier: "list_chat", label: nil, value: nil,
                               placeholder: nil, enabled: true,
                               frame: FTRect(x: 0, y: 485, width: 1080, height: 930), depth: 2, scrollable: true)
        let carousel = ElementInfo(ref: 2, type: "scrollView", identifier: "tags", label: nil, value: nil,
                                   placeholder: nil, enabled: true,
                                   frame: FTRect(x: 0, y: 600, width: 1080, height: 300), depth: 3, scrollable: true,
                                   scrollActions: ["left", "right"])
        let snapshot = SnapshotResponse(sessionBundleID: nil, screen: screenRect, elements: [list, carousel],
                                        truncatedCount: 0, keyboardShown: true,
                                        keyboardFrame: FTRect(x: 0, y: 1541, width: 1080, height: 859))
        XCTAssertEqual(StepExecutor.keyboardScrollContainer(in: snapshot, vertical: true)?.identifier, "list_chat")
        let none = SnapshotResponse(sessionBundleID: nil, screen: screenRect, elements: [carousel],
                                    truncatedCount: 0, keyboardShown: true,
                                    keyboardFrame: FTRect(x: 0, y: 1541, width: 1080, height: 859))
        XCTAssertNil(StepExecutor.keyboardScrollContainer(in: none, vertical: true),
                     "縦に払えない容器しか無ければ nil(画面全体のまま)")
    }
}
