// OI-374: 説明(contentDescription)だけから来たラベルに、可視性検証が描かれた文字を求めない条件。
// 判定は `DescriptionOnlyLabel` の1箇所(DSL の V9 が呼ぶ)。

import XCTest
@testable import FTCore

final class DescriptionOnlyLabelTests: XCTestCase {
    private func el(_ ref: Int, _ type: String = "staticText", label: String? = "No formula",
                    depth: Int = 0, source: String? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: nil, label: label, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: depth,
                    labelSource: source)
    }

    private func skips(_ tree: [ElementInfo], _ app: AppUIFramework?, text: String = "No formula") -> Bool {
        DescriptionOnlyLabel.skipsDrawnTextCheck(element: tree[0], expectedText: text, in: tree, app: app)
    }

    func testDescOnlyLabelOnViewOrComposeIsSkipped() {
        let tree = [el(1, source: "desc")]
        XCTAssertTrue(skips(tree, .androidView))
        XCTAssertTrue(skips(tree, .compose))
    }

    func testFlutterIsNeverSkipped() {
        XCTAssertFalse(skips([el(1, source: "desc")], .flutter))
    }

    func testUnknownFrameworkKeepsCurrentBehaviour() {
        XCTAssertFalse(skips([el(1, source: "desc")], nil))
    }

    func testTextOriginLabelIsNotSkipped() {
        XCTAssertFalse(skips([el(1)], .androidView))
    }

    func testReactNativeButtonWithSameTextChildIsNotSkipped() {
        let tree = [el(1, "button", source: "desc"), el(2, depth: 1)]
        XCTAssertFalse(skips(tree, .reactNative))
    }

    func testDescOnlyChildWithSameLabelDoesNotCountAsDrawn() {
        let tree = [el(1, "button", source: "desc"), el(2, depth: 1, source: "desc")]
        XCTAssertTrue(skips(tree, .androidView))
    }

    func testChildWithOtherLabelDoesNotBlockSkip() {
        let tree = [el(1, "button", source: "desc"), el(2, label: "other", depth: 1)]
        XCTAssertTrue(skips(tree, .androidView))
    }

    func testExpectedTextMustBeTheElementsOwnLabel() {
        XCTAssertFalse(skips([el(1, source: "desc")], .androidView, text: "something else"))
    }

    func testLabelSourceDecodesAndIsAbsentByDefault() throws {
        let json = #"{"ref":1,"type":"StaticText","label":"x","enabled":true,"frame":{"x":0,"y":0,"width":1,"height":1},"depth":0,"labelSource":"desc"}"#
        XCTAssertEqual(try JSONDecoder().decode(ElementInfo.self, from: Data(json.utf8)).labelSource, "desc")
        let bare = json.replacingOccurrences(of: #","labelSource":"desc""#, with: "")
        XCTAssertNil(try JSONDecoder().decode(ElementInfo.self, from: Data(bare.utf8)).labelSource)
    }
}
