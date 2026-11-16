// スコープ `>>` の子孫は「木に出した祖先の数」(ElementInfo.keptDepth)で引く(OI-237)。
// 木は E2EY-Flutter の入れ子スクロールを in-app で採った形: `#txt_nested_result` は depth 7 の葉で、直後に
// 出さなかった兄弟の入れ物(Expanded の ListView)の中身 `#list_nested` が depth 8 で並ぶ

import XCTest
@testable import FTCore

final class ScopeKeptDepthTests: XCTestCase {

    private func node(_ ref: Int, _ type: String, depth: Int, kept: Int?, id: String? = nil,
                      _ y: Double, _ height: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: y, width: 402, height: height), depth: depth, keptDepth: kept)
    }

    private func tree(kept: Bool) -> [ElementInfo] {
        [
            node(1, "other", depth: 5, kept: kept ? 0 : nil, id: "screen_nested", 0, 874),
            node(2, "staticText", depth: 7, kept: kept ? 1 : nil, id: "txt_nested_result", 120, 20),
            node(3, "other", depth: 8, kept: kept ? 1 : nil, id: "list_nested", 150, 700),
            node(4, "other", depth: 9, kept: kept ? 2 : nil, id: "shelf_0", 150, 200),
            node(5, "button", depth: 10, kept: kept ? 3 : nil, id: "card_0_01", 160, 180),
        ]
    }

    private func scoped(_ target: String, _ container: String) -> FlowLocator {
        var locator = FlowLocator(id: target)
        locator.scope = [FlowLocator(id: container)]
        return locator
    }

    /// 中身を持たない文字を容器にしたら、隣の一覧のカードを解決しない(容器に中身が無い、と言う側へ回る)
    func testLeafContainerDoesNotAdoptThePrunedSiblingsContent() {
        let elements = tree(kept: true)
        let locator = scoped("card_0_01", "txt_nested_result")
        XCTAssertEqual(LocatorResolver.candidates(locator, elements: elements)?.count, 0)
        XCTAssertEqual(LocatorResolver.childlessScopeContainer(of: locator, in: elements)?.identifier, "txt_nested_result")
        // 本物の容器では引ける(入れ子の2段も)
        XCTAssertEqual(LocatorResolver.candidates(scoped("card_0_01", "list_nested"), elements: elements)?.map(\.ref), [5])
        XCTAssertEqual(LocatorResolver.scopeDescendants(of: elements[2], in: elements).map(\.ref), [4, 5])
        XCTAssertEqual(LocatorResolver.scopeDescendants(of: elements[0], in: elements).map(\.ref), [2, 3, 4, 5])
    }

    /// keptDepth の無い木(ホストで組んだ木)は depth で引く = 従来どおり
    func testTreeWithoutKeptDepthFallsBackToDepth() {
        let elements = tree(kept: false)
        XCTAssertEqual(LocatorResolver.candidates(scoped("card_0_01", "txt_nested_result"), elements: elements)?.map(\.ref), [5])
        // 1つでも欠けていれば depth で引く(混ざった木で深さの物差しが割れないように)
        var mixed = tree(kept: true)
        mixed[4].keptDepth = nil
        XCTAssertEqual(LocatorResolver.scopeDescendants(of: mixed[1], in: mixed).map(\.ref), [3, 4, 5])
    }

    /// スコープの提案もこの子孫で組む: 中身を持たない葉を容器にした `.型[n]` を出さない
    func testScopedSelectorDoesNotProposeALeafAsTheContainer() {
        let elements = tree(kept: true)
        let snapshot = SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                        elements: elements, truncatedCount: 0)
        XCTAssertNil(SelectorNaming.scopedSelector(scope: elements[1], for: elements[4], in: snapshot))
        XCTAssertEqual(SelectorNaming.scopedSelector(scope: elements[2], for: elements[4], in: snapshot),
                       "#list_nested >> .button[1]")
    }

    // MARK: - ブリッジの数え方(BridgeAPI.keptParents / keptDepths。in-app と XCUITest が共有)

    /// 出さなかった祖先は飛ばし、出した直近の祖先を親にする
    func testKeptParentsSkipAncestorsThatWereNotKept() {
        // 0 根 ─ 1 葉(文字) / 2(落とした入れ物)─ 3 一覧 ─ 4 カード
        let parents: [Int?] = [nil, 0, 0, 2, 3]
        let order = [0, 1, 3, 4]   // 2 を落とした
        let keptParents = BridgeAPI.keptParents(parents: parents, order: order)
        XCTAssertEqual(keptParents, [nil, 0, 0, 2])
        XCTAssertEqual(BridgeAPI.keptDepths(keptParents: keptParents), [0, 1, 1, 2])
    }

    /// 間引きで中間の要素を落としても、その子は落とした要素の親へ繋がる。根が複数(窓ごと)でも各々 0 から
    func testKeptParentsAcrossThinningAndSeveralRoots() {
        let parents: [Int?] = [nil, 0, 1, 2, nil, 4]
        let order = [0, 2, 3, 4, 5]   // 1 を間引いた
        let keptParents = BridgeAPI.keptParents(parents: parents, order: order)
        XCTAssertEqual(keptParents, [nil, 0, 1, nil, 3])
        XCTAssertEqual(BridgeAPI.keptDepths(keptParents: keptParents), [0, 1, 2, 0, 1])
    }

    /// ワイヤから読む(欄が無ければ nil)
    func testDecodesKeptDepth() throws {
        let json = #"{"ref":1,"type":"Button","enabled":true,"frame":{"x":0,"y":0,"width":1,"height":1},"depth":7,"keptDepth":2}"#
        XCTAssertEqual(try JSONDecoder().decode(ElementInfo.self, from: Data(json.utf8)).keptDepth, 2)
        let without = #"{"ref":1,"type":"Button","enabled":true,"frame":{"x":0,"y":0,"width":1,"height":1},"depth":7}"#
        XCTAssertNil(try JSONDecoder().decode(ElementInfo.self, from: Data(without.utf8)).keptDepth)
    }
}
