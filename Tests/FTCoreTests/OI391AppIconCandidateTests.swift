import XCTest
@testable import FTCore

/// Android のランチャーのドロワーで、上端で切れた行・検索バーに中心を覆われた行・同名で重複した行を撃たない。
/// 木は Pixel 3a の観測の形(apps_list_view の上端で切れて縮んだ行の中心が検索バーの中)を最小にしたもの
final class OI391AppIconCandidateTests: XCTestCase {

    private func el(_ ref: Int, _ type: String, id: String? = nil, label: String? = nil,
                    _ frame: FTRect, depth: Int, z: Int, scrollable: Bool? = nil) -> ElementInfo {
        var e = ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil, placeholder: nil,
                            enabled: true, frame: frame, depth: depth)
        e.z = z
        e.scrollable = scrollable
        return e
    }

    private static let name = "FT E2E Android"
    private let list = FTRect(x: 0, y: 300, width: 1080, height: 1900)
    private let clippedRow = FTRect(x: 238, y: 300, width: 201, height: 118)
    private let fullRow = FTRect(x: 238, y: 1500, width: 201, height: 316)
    private let searchBar = FTRect(x: 0, y: 200, width: 1080, height: 200)

    private func tree(rows: [ElementInfo], withSearchBar: Bool = true) -> SnapshotResponse {
        var elements = [el(1, "scrollView", id: "apps_list_view", list, depth: 0, z: 10, scrollable: true)]
        elements += rows
        // 切れた行を「本来の高さ」と比べる材料(同じ深さ・同じ型の背の高い兄弟が2件以上)
        elements.append(el(20, "button", label: "Other1", FTRect(x: 640, y: 700, width: 201, height: 316), depth: 1, z: 11))
        elements.append(el(21, "button", label: "Other2", FTRect(x: 640, y: 1100, width: 201, height: 316), depth: 1, z: 11))
        if withSearchBar {
            elements.append(el(30, "textView", id: "search_bar", label: "Search", searchBar, depth: 0, z: 47))
        }
        return SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 1080, height: 2220),
                                elements: elements, truncatedCount: 0)
    }

    private func icon(_ ref: Int, _ frame: FTRect) -> ElementInfo {
        el(ref, "button", label: Self.name, frame, depth: 1, z: 11)
    }

    /// 直す前の選び方(ラベル一致の先頭)は切れた行を選ぶ = 観測された誤り。直した選び方は選ばない
    func testClippedRowUnderSearchBarIsNotChosen() {
        let snap = tree(rows: [icon(2, clippedRow)])
        XCTAssertEqual(AppIconLocator.findIcon(Self.name, in: snap)?.ref, 2, "旧実装の選び方(再現の前提)")
        XCTAssertNil(AppIconLocator.findTappableIcon(Self.name, in: snap, isAndroid: true))
        XCTAssertEqual(AppIconLocator.matches(Self.name, in: snap).count, 1, "一致はあった = 呼び手が「撃てなかった」と言える")
    }

    /// 検索バーが無くても、縁で切れて縮んだ枠は撃たない(覆いと切れは別の条件)
    func testClippedRowAtListEdgeIsNotChosenEvenWhenNothingCoversIt() {
        let snap = tree(rows: [icon(2, clippedRow)], withSearchBar: false)
        XCTAssertNil(AppIconLocator.findTappableIcon(Self.name, in: snap, isAndroid: true))
    }

    /// 同名が2つ(切れた行と見えている行): 先頭の切れた方でなく見えている方を取る
    func testDuplicateNameChoosesTheVisibleOne() {
        let snap = tree(rows: [icon(2, clippedRow), icon(3, fullRow)])
        XCTAssertEqual(AppIconLocator.findIcon(Self.name, in: snap)?.ref, 2)
        XCTAssertEqual(AppIconLocator.findTappableIcon(Self.name, in: snap, isAndroid: true)?.ref, 3)
    }

    /// 健全な行(満高・覆われていない)はそのまま選ぶ
    func testHealthyRowIsChosen() {
        let snap = tree(rows: [icon(3, fullRow)])
        XCTAssertEqual(AppIconLocator.findTappableIcon(Self.name, in: snap, isAndroid: true)?.ref, 3)
    }

    /// 手前の要素が下端のはみ出し行を覆う形(Pixel 4a: overview_actions_view の下の行)
    func testRowUnderBottomOverlayIsNotChosen() {
        let covered = FTRect(x: 636, y: 2296 - 100, width: 194, height: 44)
        var snap = tree(rows: [icon(2, covered)], withSearchBar: false)
        snap.elements.append(el(40, "button", id: "overview_actions_view", label: "Screenshot",
                                FTRect(x: 0, y: 2150, width: 1080, height: 120), depth: 0, z: 57))
        XCTAssertNil(AppIconLocator.findTappableIcon(Self.name, in: snap, isAndroid: true))
    }

    /// iOS は従来どおり(ホームの木は塗り順を持たない。この絞りを持ち込まない)
    func testIOSKeepsFirstMatch() {
        let snap = tree(rows: [icon(2, clippedRow)])
        XCTAssertEqual(AppIconLocator.findTappableIcon(Self.name, in: snap, isAndroid: false)?.ref, 2)
    }

    /// Pixel 3a の実測の形: アイコンは staticText(型の門のある切れの判定は見ない)。一覧の上端で高さ 88 に縮んだ行は撃てない
    func testStaticTextIconClippedAtListTopIsNotFree() {
        let row = FTRect(x: 439, y: 195, width: 201, height: 88)
        var elements = [el(1, "collectionView", id: "apps_list_view", FTRect(x: 0, y: 195, width: 1080, height: 2025),
                           depth: 0, z: 10, scrollable: true)]
        elements.append(el(2, "staticText", id: "icon", label: "Firefox", row, depth: 1, z: 11))
        elements.append(el(3, "staticText", id: "icon", label: "Other1", FTRect(x: 439, y: 700, width: 201, height: 316), depth: 1, z: 11))
        elements.append(el(4, "staticText", id: "icon", label: "Other2", FTRect(x: 439, y: 1100, width: 201, height: 316), depth: 1, z: 11))
        let snap = SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 1080, height: 2220),
                                    elements: elements, truncatedCount: 0)
        XCTAssertFalse(AppIconLocator.isFreeToTap(elements[1], in: snap))
        XCTAssertTrue(AppIconLocator.isFreeToTap(elements[2], in: snap), "満高の行は撃てる")
    }
}
