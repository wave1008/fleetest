// interactiveOnly が「操作できる祖先と同じ中身」として隠す行(`SnapshotRenderer.isRedundantWithOperableAncestor`)。
// witness: Google マップ(Android)の場所カードでカテゴリ「城」が `clickable "大阪城"` に偶然含まれて隠れた・
// Apple マップの検索結果で評価の行が、祖先のボタンの 40 文字で切られた先にだけあって隠れた(どちらも取り直しに1手)

import XCTest
@testable import FTCore

final class InteractiveOnlyRedundancyTests: XCTestCase {

    private func el(_ ref: Int, _ type: String, _ label: String, y: Double, height: Double, depth: Int) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: nil, label: label, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: y, width: 400, height: height), depth: depth)
    }

    private func rendered(_ elements: [ElementInfo]) -> String {
        SnapshotRenderer.render(SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                                 elements: elements, truncatedCount: 0), interactiveOnly: true)
    }

    func testATextThatOnlyHappensToSitInsideASiblingsLabelStays() {
        let text = rendered([el(1, "clickable", "大阪城", y: 100, height: 200, depth: 0),
                             el(2, "staticText", "大阪城", y: 110, height: 40, depth: 1),
                             el(3, "staticText", "4.4 星 (102,761)", y: 150, height: 20, depth: 1),
                             el(4, "staticText", "城", y: 170, height: 20, depth: 1)])
        XCTAssertTrue(text.contains("[4] staticText \"城\""), text)
        XCTAssertFalse(text.contains("[2] staticText"), "祖先と同じ文字の行まで出した: \(text)")
    }

    func testATextCutOffTheAncestorsLineStays() {
        let label = "上野精養軒 東京都美術館店 カフェ•アート cafe Art、カフェ · 台東区 · ¥、9:30に営業開始 ·  3.5 食べログ"
        let text = rendered([el(1, "button", label, y: 100, height: 80, depth: 0),
                             el(2, "staticText", "カフェ · 台東区", y: 120, height: 20, depth: 1),
                             el(3, "staticText", "9:30に営業開始 ·  3.5 食べログ", y: 140, height: 20, depth: 1)])
        XCTAssertTrue(text.contains("[3] staticText"), "切られた先の評価を隠した: \(text)")
        XCTAssertFalse(text.contains("[2] staticText"), "描かれる部分にある行まで出した: \(text)")
    }

    func testPartsOfAShortJoinedLabelStayHidden() {
        let text = rendered([el(1, "button", "電話番号, +81 3 3433 5111", y: 100, height: 60, depth: 0),
                             el(2, "staticText", "電話番号", y: 105, height: 20, depth: 1),
                             el(3, "staticText", "+81 3 3433 5111", y: 130, height: 20, depth: 1)])
        XCTAssertFalse(text.contains("[2] staticText") || text.contains("[3] staticText"), text)
    }
}
