import XCTest
@testable import FTCore

/// id もラベルも持たない要素は、近くの一意な要素からの相対セレクタで書ける
final class SelectorNamingRelativeTests: XCTestCase {

    private func element(_ ref: Int, type: String, label: String? = nil, x: Double, y: Double,
                         width: Double = 100) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: nil, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: width, height: 40), depth: 1)
    }

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                         elements: elements, truncatedCount: 0)
    }

    /// 同じ型の無名スイッチが並ぶ行。一意なラベルを基準に `:rightSwitch` で書け、
    /// 書いた文字列を parse → 解決すると元の要素へ戻る
    func testUnnamedSwitchIsWrittenRelativeToTheUniqueLabelBesideIt() throws {
        let snap = snapshot([
            element(1, type: "staticText", label: "通知", x: 16, y: 100),
            element(2, type: "switch", x: 300, y: 100, width: 50),
            element(3, type: "staticText", label: "メール", x: 16, y: 200),
            element(4, type: "switch", x: 300, y: 200, width: 50),
        ])
        let naming = SelectorNaming(snap)
        for (target, expected) in [(snap.elements[1], "通知:rightSwitch"),
                                   (snap.elements[3], "メール:rightSwitch")] {
            let graded = try XCTUnwrap(naming.graded(for: target, in: snap))
            XCTAssertEqual(graded.selector, expected)
            XCTAssertEqual(graded.durability, .relative, "位置依存なので印を付ける(索引形とは別の格付け)")
            let parsed = FTSelector.parse(graded.selector)
            XCTAssertEqual(LocatorResolver.matchDetailed(parsed.primary, elements: snap.elements)?.0.ref,
                           target.ref, "書いたセレクタが元の要素へ戻らない")
        }
    }

    /// キーボードの部品(inputView 等)は錨にしない: 近くにあっても、無名の要素の相対セレクタの基準に採らない
    func testKeyboardChromeIsNeverTheAnchor() {
        var keyboard = element(1, type: "other", x: 0, y: 500, width: 400)
        keyboard = ElementInfo(ref: 1, type: "other", identifier: "inputView", label: nil, value: nil,
                               placeholder: nil, enabled: true, frame: keyboard.frame, depth: 1)
        let snap = snapshot([
            keyboard,
            element(2, type: "switch", x: 300, y: 460, width: 50),
            element(3, type: "switch", x: 300, y: 100, width: 50),
        ])
        let selector = SelectorNaming(snap).selector(for: snap.elements[1], in: snap)
        XCTAssertFalse(selector?.contains("inputView") ?? false, selector ?? "nil")
    }

    /// 申告されたキーボードの範囲にある要素(id が chrome 名でない部品)は錨にしない。申告が無ければ従来どおり錨になる
    func testElementInsideTheReportedKeyboardIsNotTheAnchor() throws {
        // キーボードの部品は根(`inputView`)の部分木。実物の木(ios-maps_suggest_keyboard)と同じ形
        let root = ElementInfo(ref: 4, type: "other", identifier: "inputView", label: nil, value: nil,
                               placeholder: nil, enabled: true,
                               frame: FTRect(x: 0, y: 538, width: 400, height: 262), depth: 1)
        let part = ElementInfo(ref: 1, type: "scrollView", identifier: "CenterPageView", label: nil, value: nil,
                               placeholder: nil, enabled: true,
                               frame: FTRect(x: 0, y: 538, width: 400, height: 45), depth: 2)
        let field = element(2, type: "textField", x: 50, y: 300, width: 300)
        let other = element(3, type: "textField", x: 50, y: 200, width: 300)
        func snap(keyboard: FTRect?) -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                             elements: [field, other, root, part], truncatedCount: 0, keyboardFrame: keyboard)
        }
        let withKeyboard = snap(keyboard: FTRect(x: 0, y: 538, width: 400, height: 262))
        XCTAssertNil(SelectorNaming(withKeyboard).selector(for: withKeyboard.elements[0], in: withKeyboard))
        let without = snap(keyboard: nil)
        let selector = try XCTUnwrap(SelectorNaming(without).selector(for: without.elements[0], in: without))
        XCTAssertTrue(selector.contains("CenterPageView"), selector)
    }

    /// 基準にできる一意な要素が無ければ、これまでどおり書けない(nil)
    func testNoUniqueAnchorStillYieldsNil() {
        let snap = snapshot([
            element(1, type: "switch", x: 300, y: 100, width: 50),
            element(2, type: "switch", x: 300, y: 200, width: 50),
        ])
        XCTAssertNil(SelectorNaming(snap).selector(for: snap.elements[0], in: snap))
    }

    /// 最寄りが別の要素なら採らない(当人へ戻らない候補を勧めない)
    func testRelativeSelectorThatResolvesElsewhereIsRejected() {
        let snap = snapshot([
            element(1, type: "staticText", label: "通知", x: 16, y: 100),
            element(2, type: "switch", x: 150, y: 100, width: 50),
            element(3, type: "switch", x: 300, y: 100, width: 50),
        ])
        XCTAssertNil(SelectorNaming(snap).selector(for: snap.elements[2], in: snap),
                     "右の最寄りは ref 2 なので ref 3 には書けない")
    }
}
