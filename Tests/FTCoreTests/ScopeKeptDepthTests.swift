// スコープ `>>` の子孫は「木に出した祖先の数」(ElementInfo.keptDepth)で引く。
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

    // MARK: - Flutter の容器の数え方(XCUITest ランナーの gather と同じ部品の組み合わせ)

    private struct FakeNode {
        var name: String
        var kept: Bool
        var cls: String? = nil
        var children: [FakeNode] = []
        var isLeafOther: Bool { children.isEmpty }
    }

    /// ランナーの `gather` と同じ手順(問う形か → クラス名 → 先頭の子を出したら親を付け替える)。問った回数も返す
    private func walk(_ node: FakeNode, parent: Int?, names: inout [String], parents: inout [Int?], queries: inout Int) {
        if node.kept { names.append(node.name); parents.append(parent) }
        var childParents = BridgeAPI.SemanticsContainerChildren(
            parent: node.kept ? names.count - 1 : parent,
            tracksOwn: BridgeAPI.shouldQuerySemanticsContainer(
                included: node.kept, childCount: node.children.count,
                firstChildIsLeafOther: node.children.first?.isLeafOther ?? false)
                && { queries += 1; return BridgeAPI.isSemanticsContainerClass(node.cls) }())
        for (at, child) in node.children.enumerated() {
            let before = names.count
            walk(child, parent: childParents.parent, names: &names, parents: &parents, queries: &queries)
            childParents.finishedChild(isFirst: at == 0, gatheredIndexIfKept: names.count > before && names[before] == child.name ? before : nil)
        }
    }

    private func depths(_ root: FakeNode) -> (names: [String], depths: [Int], queries: Int) {
        var names: [String] = [], parents: [Int?] = [], queries = 0
        walk(root, parent: nil, names: &names, parents: &parents, queries: &queries)
        let kept = BridgeAPI.keptParents(parents: parents, order: Array(parents.indices))
        return (names, BridgeAPI.keptDepths(keptParents: kept), queries)
    }

    /// 本物の容器: 先頭の子(出す)の中身が後ろの兄弟 = 先頭の子の子孫に数える
    func testFlutterContainerCountsSiblingsAsTheFirstChildsContent() {
        let tree = FakeNode(name: "root", kept: true, children: [
            FakeNode(name: "container", kept: false, cls: "SemanticsObjectContainer", children: [
                FakeNode(name: "list", kept: true), FakeNode(name: "card", kept: true)])])
        let r = depths(tree)
        XCTAssertEqual(r.names, ["root", "list", "card"])
        XCTAssertEqual(r.depths, [0, 1, 2])
        XCTAssertEqual(r.queries, 1)
    }

    /// 症状の形: 葉(文字)の後ろに並ぶ、出さない入れ物の中身は葉の子孫に数えない
    func testLeafFollowedByDroppedContainerIsNotItsParent() {
        let tree = FakeNode(name: "root", kept: true, children: [
            FakeNode(name: "text", kept: true),
            FakeNode(name: "container", kept: false, cls: "SemanticsObjectContainer", children: [
                FakeNode(name: "list", kept: true), FakeNode(name: "card", kept: true)])])
        XCTAssertEqual(depths(tree).depths, [0, 1, 1, 2])
    }

    /// 問いの失敗(nil)・別のクラスは木の親子のまま(後ろの兄弟は先頭の子の兄弟)。形が違えば問わない
    func testFailedOrOtherClassKeepsTreeParentage() {
        for cls in [nil, "UIAccessibilityElement"] as [String?] {
            let tree = FakeNode(name: "root", kept: true, children: [
                FakeNode(name: "container", kept: false, cls: cls, children: [
                    FakeNode(name: "list", kept: true), FakeNode(name: "card", kept: true)])])
            XCTAssertEqual(depths(tree).depths, [0, 1, 1], "\(String(describing: cls))")
        }
        let notShaped = FakeNode(name: "root", kept: true, children: [
            FakeNode(name: "group", kept: false, cls: "SemanticsObjectContainer", children: [
                FakeNode(name: "a", kept: true, children: [FakeNode(name: "x", kept: true)]), FakeNode(name: "b", kept: true)]),
            FakeNode(name: "single", kept: false, cls: "SemanticsObjectContainer", children: [FakeNode(name: "c", kept: true)])])
        let r = depths(notShaped)
        XCTAssertEqual(r.queries, 0)
        XCTAssertEqual(r.depths, [0, 1, 2, 1, 1])
    }

    /// 先頭の子を出さなかったとき(間引き・不可視)は付け替えない
    func testFirstChildNotKeptDoesNotReparent() {
        let tree = FakeNode(name: "root", kept: true, children: [
            FakeNode(name: "container", kept: false, cls: "SemanticsObjectContainer", children: [
                FakeNode(name: "own", kept: false), FakeNode(name: "card", kept: true)])])
        XCTAssertEqual(depths(tree).depths, [0, 1])
    }

    /// 出したノードの子は(容器の形でも)問わない = UIKit の普通の入れ子はそのまま
    func testKeptNodeIsNeverQueried() {
        let tree = FakeNode(name: "root", kept: true, children: [
            FakeNode(name: "table", kept: true, cls: "SemanticsObjectContainer", children: [
                FakeNode(name: "a", kept: true), FakeNode(name: "b", kept: true)])])
        let r = depths(tree)
        XCTAssertEqual(r.depths, [0, 1, 2, 2])
        XCTAssertEqual(r.queries, 0)
    }
}
