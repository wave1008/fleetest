// 入れ子の横の棚(縦の一覧の中の横の棚)で見つからないとき、失敗文が横へ送る形も案内する(判定は変えず文言だけ)。
// 対象がどの棚にあるかは言わない(木に材料が無い)。
import XCTest
@testable import FTCore

final class HorizontalShelfHintTests: XCTestCase {
    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    private func el(_ ref: Int, _ type: String, _ f: FTRect, id: String? = nil, scrollable: Bool? = nil, depth: Int = 0) -> ElementInfo {
        var e = ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil, placeholder: nil,
                            enabled: true, frame: f, depth: depth)
        e.scrollable = scrollable
        return e
    }

    /// 縦の一覧(収まっている)の中に横の棚。`overflow` = 棚の最後のカードが右の縁をまたぐか
    private func tree(overflow: Bool, shelfId: String? = "shelf_1") -> SnapshotResponse {
        let cardWidth = overflow ? 260.0 : 100.0
        return SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [
            el(1, "other", FTRect(x: 0, y: 100, width: 402, height: 700), id: "list_nested", scrollable: true, depth: 0),
            el(2, "other", FTRect(x: 16, y: 300, width: 370, height: 150), id: shelfId, scrollable: true, depth: 1),
            el(3, "button", FTRect(x: 16, y: 300, width: 150, height: 150), id: "card_1_00", depth: 2),
            el(4, "button", FTRect(x: 180, y: 300, width: cardWidth, height: 150), id: "card_1_01", depth: 2),
        ], truncatedCount: 0)
    }

    func testShelfWhoseContentRunsPastTheEdgeIsNamed() {
        let hint = StepExecutor.scrollOffHint(FlowStep(action: "tap"), in: tree(overflow: true))
        XCTAssertTrue(hint.contains("withScrollRight(scrollFrame: <that shelf>)"), hint)
        XCTAssertTrue(hint.contains("#shelf_1"), hint)
        XCTAssertFalse(hint.contains("card_1_03"), "対象がどの棚にあるかは言わない: \(hint)")
    }

    /// 子が縁で切られて収まって見える棚(in-app の木)でも、容器の申告(content 435 > visible 402)があれば挙げる
    private func extentTree(content: Double?) -> SnapshotResponse {
        var snap = tree(overflow: false)
        if let content {
            snap.elements[1].scrollExtent = ScrollExtent(offsetX: 0, offsetY: 0, contentWidth: content, contentHeight: 150,
                                                         visibleWidth: 370, visibleHeight: 150)
        }
        return snap
    }

    func testShelfWithClippedChildrenButWiderContentIsNamed() {
        XCTAssertEqual(StepExecutor.horizontalOverflowingShelves(in: extentTree(content: 435)), ["#shelf_1"])
    }

    func testShelfWhoseExtentEqualsVisibleIsNotNamed() {
        XCTAssertEqual(StepExecutor.horizontalOverflowingShelves(in: extentTree(content: 370)), [])
    }

    func testShelfWithoutExtentKeepsOldBehaviour() {
        XCTAssertEqual(StepExecutor.horizontalOverflowingShelves(in: extentTree(content: nil)), [])
        XCTAssertEqual(StepExecutor.horizontalOverflowingShelves(in: tree(overflow: true)), ["#shelf_1"])
    }

    func testShelfScrolledAwayFromStartIsNamed() {
        var snap = extentTree(content: 370)
        snap.elements[1].scrollExtent?.offsetX = 40
        XCTAssertEqual(StepExecutor.horizontalOverflowingShelves(in: snap), ["#shelf_1"])
    }

    func testShelfThatFitsIsNotNamed() {
        let hint = StepExecutor.scrollOffHint(FlowStep(action: "tap"), in: tree(overflow: false))
        XCTAssertFalse(hint.contains("withScrollRight"), hint)
    }

    func testShelfWithoutSelectorIsNotNamed() {
        let hint = StepExecutor.scrollOffHint(FlowStep(action: "tap"), in: tree(overflow: true, shelfId: nil))
        XCTAssertFalse(hint.contains("withScrollRight"), hint)
    }

    func testDirectionGivenOrNonTouchActionAddsNothing() {
        XCTAssertEqual(StepExecutor.scrollOffHint(FlowStep(action: "tap", direction: "down"), in: tree(overflow: true)), "")
        XCTAssertFalse(StepExecutor.scrollOffHint(FlowStep(action: "wait"), in: tree(overflow: true)).contains("withScrollRight"))
    }

    /// 縦の容器しか無い画面(縦の一覧の行が左右にまたがらない)には棚の案内を足さない
    func testVerticalOnlyScreenHasNoShelfHint() {
        let snap = SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [
            el(1, "other", FTRect(x: 0, y: 174, width: 402, height: 700), id: "list", scrollable: true),
            el(2, "button", FTRect(x: 0, y: 850, width: 402, height: 48), depth: 1)], truncatedCount: 0)
        let hint = StepExecutor.scrollOffHint(FlowStep(action: "tap"), in: snap)
        XCTAssertTrue(hint.contains("scroll: .down, or .up"), hint)
        XCTAssertFalse(hint.contains("withScrollRight"), hint)
    }

    /// 固定コーパスの全数: 棚を挙げる画面と挙げた容器(2026-11-25 に1件ずつ見た)。増えたら1件ずつ見てから変える
    func testRealAppCorpusShelfHints() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RealAppSnapshots")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThan(files.count, 40)
        var named: [String] = []
        for file in files {
            let snap = try JSONDecoder().decode(SnapshotResponse.self, from: Data(contentsOf: file))
            let shelves = StepExecutor.horizontalOverflowingShelves(in: snap)
            if !shelves.isEmpty { named.append("\(file.lastPathComponent): \(shelves.joined(separator: " | "))") }
        }
        // 基準(2026-11-25): 横の棚を挙げる画面は3枚・どれも実際に横へ送る容器(乗車カードの横並び・ニュースのタブのページャ・おすすめガイドの横並び)
        XCTAssertEqual(named, ["ios-maps_transit_boarding_cards.json: #TransitDirectionsBoardingInfoListView",
                               "ios-news_feed.json: #crui_newsView_tabView",
                               "ios-place_guides_scrolled.json: #MUCuratedGuidesSectionView"], named.joined(separator: "\n"))
    }
}
