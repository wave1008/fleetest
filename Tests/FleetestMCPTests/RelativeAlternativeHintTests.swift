// 重複ラベル・重複 id の注記が、索引形(位置依存)しか書けない要素へ相対形も出すことを固定する。
// 実測: Google マップの検索候補(同名の行が住所行だけで区別できる)と Apple マップの経路の
// `#DetailButton` ×10(隣の文字だけが違う)で、索引形しか出ず読み手が順序へ逃げて別の駅を選んだ。

import XCTest
import FTCore
@testable import fleetest_mcp

final class RelativeAlternativeHintTests: XCTestCase {

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app",
                         screen: FTRect(x: 0, y: 0, width: 1080, height: 2000),
                         elements: elements, truncatedCount: 0)
    }

    private func el(_ ref: Int, _ type: String, id: String? = nil, label: String? = nil, depth: Int,
                    x: Double, y: Double, w: Double, h: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: x, y: y, width: w, height: h), depth: depth)
    }

    private func resolvedRef(_ selector: String, in snapshot: SnapshotResponse) -> Int? {
        LocatorResolver.matchDetailed(FTSelector.parse(selector).primary,
                                      elements: snapshot.elements)?.0.ref
    }

    /// 同名の見出しを持つ6行(住所行だけが違う)。行 = clickable、中に見出しと住所
    private func suggestionList() -> SnapshotResponse {
        var out = [el(1, "collectionView", id: "suggest", depth: 1, x: 0, y: 200, w: 1080, h: 1000)]
        for i in 0..<6 {
            let y = 226 + Double(i) * 161
            let ref = 2 + i * 3
            out.append(el(ref, "clickable", label: "立川駅", depth: 2, x: 0, y: y, w: 1080, h: 158))
            out.append(el(ref + 1, "staticText", label: "立川駅", depth: 3, x: 210, y: y + 21, w: 128, h: 62))
            out.append(el(ref + 2, "staticText", label: "日本、東京都立川市\(i)", depth: 3,
                          x: 210, y: y + 83, w: 600, h: 54))
        }
        return snapshot(out)
    }

    func testSuggestionRowsGetARelativeFormThatResolvesBackToThem() throws {
        let snap = suggestionList()
        let naming = SelectorNaming(snap)
        for ref in [2, 5, 8, 11, 14, 17] {
            let row = try XCTUnwrap(snap.elements.first { $0.ref == ref })
            XCTAssertEqual(naming.graded(for: row, in: snap)?.durability, .indexed, "前提: 行の最良の形は索引形")
            let alt = try XCTUnwrap(naming.relativeAlternative(for: row, in: snap), "[\(ref)] に相対形が無い")
            XCTAssertEqual(resolvedRef(alt, in: snap), ref, "[\(ref)] の相対形 \(alt) が別の要素に解決する")
        }
        let note = MCPServer.ambiguousLabelsNote(snap)
        XCTAssertTrue(note.contains("日本、東京都立川市0:"), "住所を基準にした相対形が出ていない: \(note)")
        XCTAssertFalse(note.contains("#suggest >> .clickable"), "相対形があるのに索引形を出している: \(note)")
        XCTAssertFalse(note.contains("every alternative is index-based"), "相対形があるのに畳まれている: \(note)")
    }

    /// 同じ `#DetailButton` が10個・隣の文字だけが違う
    func testIdenticalDetailButtonsAreSeparatedByTheNeighbouringText() throws {
        var out = [el(1, "other", id: "steps", depth: 1, x: 0, y: 0, w: 1080, h: 1000)]
        // 手順ごとのセル(id なし)に文字とボタン。画面の端に一意なボタン(遠い基準 = 使わせない)
        out.append(el(100, "button", id: "EndButton", depth: 2, x: 900, y: 940, w: 60, h: 40))
        for i in 0..<10 {
            let y = 20 + Double(i) * 60
            out.append(el(2 + i * 3, "cell", depth: 2, x: 0, y: y, w: 1080, h: 50))
            out.append(el(3 + i * 3, "staticText", label: "step number \(i)", depth: 3, x: 0, y: y, w: 300, h: 40))
            out.append(el(4 + i * 3, "button", id: "DetailButton", depth: 3, x: 900, y: y, w: 60, h: 40))
        }
        let snap = snapshot(out)
        let naming = SelectorNaming(snap)
        let button = try XCTUnwrap(snap.elements.first { $0.ref == 13 })
        let alt = try XCTUnwrap(naming.relativeAlternative(for: button, in: snap))
        XCTAssertEqual(alt, "step number 3:rightButton")
        XCTAssertEqual(resolvedRef(alt, in: snap), 13, alt)
        let note = MCPServer.duplicateIDsNote(snap)
        XCTAssertTrue(note.contains("[4] step number 0:rightButton~"), note)
        XCTAssertFalse(note.contains("#EndButton:"), "行の外の部品を基準にしている: \(note)")
    }

    /// 行の中に一意な文字が無いときは、遠くの部品(画面の端のボタン)を基準にした形を出さない(並び順に頼るのと変わらない)
    func testNoAlternativeAnchoredOutsideTheOwnRow() throws {
        var out = [el(1, "other", id: "steps", depth: 1, x: 0, y: 0, w: 1080, h: 1000)]
        for i in 0..<4 {
            let y = 20 + Double(i) * 60
            out.append(el(2 + i * 2, "cell", depth: 2, x: 0, y: y, w: 1080, h: 50))
            out.append(el(3 + i * 2, "button", id: "DetailButton", depth: 3, x: 900, y: y, w: 60, h: 40))
        }
        out.append(el(100, "button", id: "EndButton", depth: 2, x: 900, y: 940, w: 60, h: 40))
        let snap = snapshot(out)
        let naming = SelectorNaming(snap)
        let last = try XCTUnwrap(snap.elements.first { $0.ref == 9 })
        XCTAssertNil(naming.relativeAlternative(for: last, in: snap), "行の外の #EndButton を基準にした")
    }

    /// ラベルも id も無い要素は「自分の行」を見分けられない = 自分の中だけを基準の範囲にする(根まで上って遠くの部品を基準にしない)
    func testUnidentifiedElementDoesNotClimbToTheRoot() throws {
        // 画面全体の根(depth 0)の下にリストと画面の端のボタン。根まで上ると #EndButton が基準に入る
        var out = [el(99, "other", depth: 0, x: 0, y: 0, w: 1080, h: 2000),
                   el(1, "other", id: "list", depth: 1, x: 0, y: 0, w: 1080, h: 1000)]
        for i in 0..<4 {
            out.append(el(2 + i, "button", depth: 2, x: 900, y: 20 + Double(i) * 60, w: 60, h: 40))
        }
        out.append(el(100, "button", id: "EndButton", depth: 1, x: 900, y: 1200, w: 60, h: 40))
        let snap = snapshot(out)
        let naming = SelectorNaming(snap)
        let last = try XCTUnwrap(snap.elements.first { $0.ref == 5 })
        XCTAssertNil(naming.relativeAlternative(for: last, in: snap), "素性の無い要素で遠くの #EndButton を基準にした")
    }

    /// ラベルも id も無いスイッチでも、同じ行の文字(行ごとに違う)を基準にした形は出る(相対セレクタの本来の用途)
    func testUnlabeledSwitchIsAnchoredOnTheLabelInItsRow() throws {
        var out = [el(99, "other", depth: 0, x: 0, y: 0, w: 1080, h: 2000),
                   el(1, "other", id: "settings", depth: 1, x: 0, y: 0, w: 1080, h: 1000)]
        for (i, name) in ["通知", "位置情報", "カメラ"].enumerated() {
            let y = 20 + Double(i) * 80
            out.append(el(10 + i * 3, "cell", depth: 2, x: 0, y: y, w: 1080, h: 70))
            out.append(el(11 + i * 3, "staticText", label: name, depth: 3, x: 20, y: y + 10, w: 300, h: 50))
            out.append(el(12 + i * 3, "switch", depth: 3, x: 900, y: y + 10, w: 120, h: 50))
        }
        let snap = snapshot(out)
        let naming = SelectorNaming(snap)
        let second = try XCTUnwrap(snap.elements.first { $0.ref == 15 })
        let alt = try XCTUnwrap(naming.relativeAlternative(for: second, in: snap))
        XCTAssertEqual(alt, "位置情報:rightSwitch")
    }

    /// 最良の形が既に stable の要素は、相対形を計算も表示もしない(注記は従来どおり)
    func testStableFormsAreUntouched() throws {
        let snap = snapshot([
            el(1, "other", id: "row_a", depth: 1, x: 0, y: 0, w: 500, h: 100),
            el(2, "button", label: "お気に入りに追加", depth: 2, x: 0, y: 10, w: 100, h: 40),
            el(3, "other", id: "row_b", depth: 1, x: 0, y: 200, w: 500, h: 100),
            el(4, "button", label: "お気に入りに追加", depth: 2, x: 0, y: 210, w: 100, h: 40),
        ])
        let naming = SelectorNaming(snap)
        XCTAssertNil(naming.relativeAlternative(for: snap.elements[1], in: snap))
        let note = MCPServer.ambiguousLabelsNote(snap)
        XCTAssertTrue(note.contains("[2] #row_a >> お気に入りに追加"), note)
        XCTAssertFalse(note.contains(":right") || note.contains(":below") || note.contains(":above"), note)
    }

    /// 実アプリ(Google マップの検索候補)でも、行へ住所行を基準にした相対形が書ける
    func testRealGoogleMapsSuggestionRowGetsARelativeForm() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RealAppSnapshots/and-maps_suggest_ime.json")
        let snap = try JSONDecoder().decode(SnapshotResponse.self, from: try Data(contentsOf: url))
        let naming = SelectorNaming(snap)
        let row = try XCTUnwrap(snap.elements.first { $0.ref == 2 })
        let alt = try XCTUnwrap(naming.relativeAlternative(for: row, in: snap))
        XCTAssertEqual(resolvedRef(alt, in: snap), 2, alt)
    }
}
