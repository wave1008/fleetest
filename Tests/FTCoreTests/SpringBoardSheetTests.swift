// SpringBoard がアプリを覆うシート(`SBSwitcherWindow` の中・アラートではない)の判定。木の形は実測(iOS 27.2 の Simulator・SE3 の実機)を写した
import XCTest
@testable import FTCore

final class SpringBoardSheetTests: XCTestCase {
    private func e(_ type: String, _ id: String?, _ label: String?, _ f: (Double, Double, Double, Double), depth: Int) -> ElementInfo {
        ElementInfo(ref: 0, type: type, identifier: id, label: label, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: f.0, y: f.1, width: f.2, height: f.3), depth: depth)
    }

    private func tree(_ elements: [ElementInfo], width: Double = 402, height: Double = 874) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.apple.springboard", screen: FTRect(x: 0, y: 0, width: width, height: height),
                         elements: elements, truncatedCount: 0)
    }

    private var statusBar: [ElementInfo] {
        [e("window", "SBSwitcherWindow:Main", nil, (0, 0, 402, 874), depth: 1),
         e("scrollView", nil, nil, (0, 0, 402, 874), depth: 6),
         e("scrollView", nil, nil, (0, -437, 402, 1311), depth: 13),
         e("staticText", nil, "22:50", (57, 14, 50, 22), depth: 26),
         e("button", "breadcrumb", "FT E2E iOSへ戻る", (12, 33, 71, 13), depth: 26),
         e("staticText", nil, "バッテリー電源100%", (333, 25, 29, 14), depth: 26)]
    }

    /// 連絡先の権限のアラートで「続ける」を押した後の限定共有の画面
    func testContactsSharingSheetIsFound() throws {
        let sheet = statusBar + [
            e("scrollView", nil, nil, (0, 0, 402, 693), depth: 38),
            e("button", nil, "Kate Bellの連絡先写真", (164, 143, 74, 74), depth: 41),
            e("button", nil, "Kate Bellの連絡先写真", (164, 150, 74, 74), depth: 41),
            e("staticText", nil, "どのように連絡先を共有しますか?", (36, 502, 321, 26), depth: 40),
            e("button", nil, "連絡先を選択", (35, 712, 332, 51), depth: 38),
            e("button", nil, "6件のすべての連絡先を共有", (35, 779, 332, 51), depth: 38)]
        let found = try XCTUnwrap(SystemUIGate.springBoardSheet(in: tree(sheet), statusBandBottom: 62))
        XCTAssertEqual(found.buttons, ["連絡先を選択", "6件のすべての連絡先を共有", "Kate Bellの連絡先写真"],
                       "幅の広い操作のボタンが先・同じラベルは1つ")
        XCTAssertEqual(SystemUIGate.sheetPhrase(found),
                       "a SpringBoard sheet (\"どのように連絡先を共有しますか?\", buttons: \"連絡先を選択\" / \"6件のすべての連絡先を共有\" / \"Kate Bellの連絡先写真\")")
    }

    /// 前面のアプリ(縦)= 帯の中のステータスバーの部品だけ
    func testAppInFrontIsNotASheet() {
        XCTAssertNil(SystemUIGate.springBoardSheet(in: tree(statusBar), statusBandBottom: 62))
    }

    /// 横向き = 入れ物だけ・ホームボタン機(SE3)= 帯 20 の中だけ
    func testLandscapeAndHomeButtonPhoneAreNotSheets() {
        let landscape = [e("window", "SBSwitcherWindow:Main", nil, (0, 0, 402, 874), depth: 1),
                         e("scrollView", nil, nil, (0, 0, 402, 874), depth: 6),
                         e("scrollView", nil, nil, (0, 0, 603, 874), depth: 13)]
        XCTAssertNil(SystemUIGate.springBoardSheet(in: tree(landscape), statusBandBottom: 0))
        let se3 = [e("window", "SBSwitcherWindow:Main", nil, (0, 0, 375, 667), depth: 1),
                   e("scrollView", nil, nil, (0, -334, 375, 1000), depth: 13),
                   e("button", "breadcrumb", "FT E2Eへ戻る", (6, 3, 52, 14), depth: 26),
                   e("staticText", nil, "0:04", (174, 3, 28, 14), depth: 26)]
        XCTAssertNil(SystemUIGate.springBoardSheet(in: tree(se3, width: 375, height: 667), statusBandBottom: 20))
    }

    /// アプリスイッチャー(カードがある)は既存の覆いの判定が受け持つ
    func testAppSwitcherWithCardsIsNotASheet() {
        let switcher = statusBar + [e("other", "card:com.ftester.e2e.ios", "FT E2E iOS", (40, 200, 320, 500), depth: 30),
                                    e("button", nil, "閉じる", (40, 720, 320, 40), depth: 31)]
        XCTAssertNil(SystemUIGate.springBoardSheet(in: tree(switcher), statusBandBottom: 62))
    }

    /// 窓の部分木の外(別の窓)の部品は数えない
    func testElementsOutsideTheSwitcherWindowAreIgnored() {
        let other = statusBar + [e("window", "SBHomeScreenWindow", nil, (0, 0, 402, 874), depth: 1),
                                 e("button", nil, "マップ", (40, 300, 60, 60), depth: 5)]
        XCTAssertNil(SystemUIGate.springBoardSheet(in: tree(other), statusBandBottom: 62))
    }
}
