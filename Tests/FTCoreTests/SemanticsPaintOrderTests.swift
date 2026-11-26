import XCTest
@testable import FTCore

/// Flutter の VM サービスの塗り順(DR-235)。固定データは段0で Emulator(E2EY-Flutter / E2EX-Flutter の debug APK)から
/// 同じ画面で撮ったダンプと木(`Tests/Fixtures/FlutterSemanticsOrder/`)。手前の正解は同時に撮った絵で確かめたもの
final class SemanticsPaintOrderTests: XCTestCase {

    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/FlutterSemanticsOrder")

    private func load(_ name: String) throws -> (dump: String, snapshot: SnapshotResponse) {
        let dump = try String(contentsOf: Self.fixtures.appendingPathComponent("\(name)-dump.txt"), encoding: .utf8)
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("\(name)-snap.json"))
        return (dump, try JSONDecoder().decode(SnapshotResponse.self, from: data))
    }

    /// 固定データの木には仮想 id が無い(段0のブリッジは出していない)ので、ブリッジの答えを identifier から組み立てる。
    /// merged up のノードは束ねた側(a11y に出るのはそちら)の id。identifier の無い要素・2つ以上に当たる identifier は載せない
    private func response(_ dump: String, _ snapshot: SnapshotResponse) -> SemanticsOrderResponse {
        struct Node { let id: Int; let depth: Int; var parent: Int?; var mergedUp = false; var identifier: String? }
        var nodes: [Int: Node] = [:]
        var stack: [Node] = []
        var current: Int?
        for line in dump.split(separator: "\n") {
            let prefixLength = line.prefix(while: { " │├└─".contains($0) }).count
            let body = line.dropFirst(prefixLength)
            if body.hasPrefix("SemanticsNode#"), let id = Int(body.dropFirst(14).prefix(while: \.isNumber)) {
                while let top = stack.last, top.depth >= prefixLength { stack.removeLast() }
                let node = Node(id: id, depth: prefixLength, parent: stack.last?.id)
                nodes[id] = node; stack.append(node); current = id
            } else if let c = current {
                let text = body.trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("merged up") { nodes[c]?.mergedUp = true }
                if text.hasPrefix("identifier: \"") { nodes[c]?.identifier = String(text.dropFirst(13).dropLast()) }
            }
        }
        func head(_ id: Int) -> Int {
            var n = nodes[id]!
            while n.mergedUp, let p = n.parent { n = nodes[p]! }
            return n.id
        }
        var heads: [String: Set<Int>] = [:]
        for n in nodes.values { if let i = n.identifier { heads[i, default: []].insert(head(n.id)) } }
        let out = snapshot.elements.compactMap { e -> SemanticsOrderResponse.Node? in
            guard let i = e.identifier, let h = heads[i], h.count == 1 else { return nil }
            return .init(ref: e.ref, semanticsId: h.first!, cx: e.frame.centerX, cy: e.frame.centerY)
        }
        return SemanticsOrderResponse(dump: dump, nodes: out, reason: nil)
    }

    private func element(_ id: String, in snapshot: SnapshotResponse) throws -> ElementInfo {
        let hits = snapshot.elements.filter { $0.identifier == id }
        XCTAssertEqual(hits.count, 1, id)
        return try XCTUnwrap(hits.first)
    }

    /// (手前, 奥) の組。どれも木の z は逆を言う(だから DR-230 は名指しを止めた)
    private static let truth: [String: [(front: String, back: String)]] = [
        "half": [("queue_row_02", "row_main_10"), ("list_queue", "row_main_06")],
        "fab": [("fab_add", "row_f_08"), ("fab_add", "row_f_09"), ("fab_extended", "row_f_10"), ("bar_action_search", "row_f_10")],
        "hide": [("bar_bottom_hiding", "row_h_12"), ("fab_hiding", "row_h_10"), ("btn_bottom_a", "row_h_12")],
    ]

    func testAnswersMatchWhatWasDrawnOnAllThreeScreens() throws {
        var treeZDisagrees = 0
        for (name, pairs) in Self.truth {
            let (dump, snapshot) = try load(name)
            let answer = try XCTUnwrap(PaintRankAnswer.make(response: response(dump, snapshot), elements: snapshot.elements), name)
            for pair in pairs {
                let front = try element(pair.front, in: snapshot), back = try element(pair.back, in: snapshot)
                XCTAssertEqual(answer.inFront(front, of: back), true, "\(name): \(pair.front) は \(pair.back) より手前")
                XCTAssertEqual(answer.inFront(back, of: front), false, "\(name): 逆向き")
                if let fz = front.z, let bz = back.z, fz < bz { treeZDisagrees += 1 }
            }
        }
        XCTAssertGreaterThanOrEqual(treeZDisagrees, 5, "前提: 木の z はこの組の多くで描画と逆")
    }

    func testRanksFollowFirstAppearanceInPreorder() {
        let dump = """
        SemanticsNode#0
         │ Rect.fromLTRB(0.0, 0.0, 10.0, 10.0)
         │
         ├─SemanticsNode#5
         │ └─SemanticsNode#9
         │     identifier: "x"
         └─SemanticsNode#3
        """
        XCTAssertEqual(FlutterSemanticsDump.ranks(dump: dump), [0: 0, 5: 1, 9: 2, 3: 3])
        XCTAssertEqual(FlutterSemanticsDump.ranks(dump: "no nodes here\n"), [:])
    }

    private func el(_ ref: Int, x: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: "button", identifier: "b\(ref)", label: nil, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: x, y: 0, width: 100, height: 100), depth: 0)
    }

    private let tinyDump = "SemanticsNode#0\n ├─SemanticsNode#1\n └─SemanticsNode#2\n"

    func testMakeDropsTheWholeAnswerWhenAnyCentreDisagrees() {
        let a = el(1, x: 0), b = el(2, x: 200)
        let good = SemanticsOrderResponse(dump: tinyDump, nodes: [.init(ref: 1, semanticsId: 1, cx: 50, cy: 50),
                                                                  .init(ref: 2, semanticsId: 2, cx: 250, cy: 50)], reason: nil)
        XCTAssertEqual(PaintRankAnswer.make(response: good, elements: [a, b])?.inFront(b, of: a), true)
        let moved = SemanticsOrderResponse(dump: tinyDump, nodes: [.init(ref: 1, semanticsId: 1, cx: 50, cy: 50),
                                                                   .init(ref: 2, semanticsId: 2, cx: 252, cy: 50)], reason: nil)
        XCTAssertNil(PaintRankAnswer.make(response: moved, elements: [a, b]), "別の木の答えは捨てる")
        let movedDown = SemanticsOrderResponse(dump: tinyDump, nodes: [.init(ref: 1, semanticsId: 1, cx: 50, cy: 50),
                                                                       .init(ref: 2, semanticsId: 2, cx: 250, cy: 51.5)], reason: nil)
        XCTAssertNil(PaintRankAnswer.make(response: movedDown, elements: [a, b]), "縦にずれた答えも捨てる")
        let withinRounding = SemanticsOrderResponse(dump: tinyDump, nodes: [.init(ref: 1, semanticsId: 1, cx: 50.5, cy: 49.5),
                                                                            .init(ref: 2, semanticsId: 2, cx: 250, cy: 50)], reason: nil)
        XCTAssertNotNil(PaintRankAnswer.make(response: withinRounding, elements: [a, b]), "1px 以内は丸めの差")
        let unknownRef = SemanticsOrderResponse(dump: tinyDump, nodes: [.init(ref: 7, semanticsId: 1, cx: 50, cy: 50)], reason: nil)
        XCTAssertNil(PaintRankAnswer.make(response: unknownRef, elements: [a, b]))
        XCTAssertNil(PaintRankAnswer.make(response: SemanticsOrderResponse(dump: nil, nodes: nil, reason: "no-vm-service"),
                                          elements: [a, b]))
        XCTAssertNil(PaintRankAnswer.make(response: nil, elements: [a, b]))
        let notInDump = SemanticsOrderResponse(dump: tinyDump, nodes: [.init(ref: 1, semanticsId: 1, cx: 50, cy: 50),
                                                                       .init(ref: 2, semanticsId: 44, cx: 250, cy: 50)], reason: nil)
        XCTAssertNil(PaintRankAnswer.make(response: notInDump, elements: [a, b])?.inFront(b, of: a), "ダンプに無い id は答えない")
    }

    func testRanksOnlyDecideThePairsTheCurrentRuleRefusesToName() throws {
        let a = el(1, x: 0), b = el(2, x: 200)
        let ranks = try XCTUnwrap(PaintRankAnswer.make(
            response: SemanticsOrderResponse(dump: tinyDump, nodes: [.init(ref: 1, semanticsId: 1, cx: 50, cy: 50),
                                                                     .init(ref: 2, semanticsId: 2, cx: 250, cy: 50)], reason: nil),
            elements: [a, b]))
        let flutter = OccluderNamingContext(isAndroid: true, framework: .flutter, paintRanks: ranks)
        XCTAssertTrue(flutter.mayName(b, a), "b が手前と答えた = 名指す")
        XCTAssertFalse(flutter.answeredBehind(b, a))
        XCTAssertFalse(flutter.mayName(a, b), "a は奥 = 名指さない")
        XCTAssertTrue(flutter.answeredBehind(a, b))
        XCTAssertFalse(OccluderNamingContext(isAndroid: true, framework: .flutter, paintRanks: nil).mayName(b, a), "答えが無ければ DR-230 のまま")
        let ios = OccluderNamingContext(isAndroid: false, framework: .flutter, paintRanks: ranks)
        XCTAssertTrue(ios.mayName(a, b), "今の規則が名指す組は答えで変えない")
        XCTAssertFalse(ios.answeredBehind(a, b))
    }

    /// 3画面の全要素で: 答えが無いと名指しを抑える組は、答えがあれば「覆いが手前」なら名指し、「奥」なら疑いごと外す。
    /// 答えで決まらない組(対応の無い要素)は DR-230 のまま抑える
    func testAdvisoryFollowsTheAnswerForEverySuppressedPair() throws {
        var named = 0, cleared = 0, kept = 0
        for name in ["half", "fab", "hide"] {
            let (dump, snapshot) = try load(name)
            let answer = try XCTUnwrap(PaintRankAnswer.make(response: response(dump, snapshot), elements: snapshot.elements))
            let base = OccluderNamingContext(isAndroid: true, framework: .flutter, paintRanks: nil)
            let withAnswer = OccluderNamingContext(isAndroid: true, framework: .flutter, paintRanks: answer)
            for target in snapshot.elements {
                let before = TapTargetGeometry.advisoryKindResult(for: target, in: snapshot.elements, screen: snapshot.screen, naming: base)
                guard before.namingSuppressed,
                      let over = OcclusionGeometry.overlayCovering(target, in: snapshot.elements, screen: snapshot.screen,
                                                                   paintOrderIsReal: false) else { continue }
                let after = TapTargetGeometry.advisoryKindResult(for: target, in: snapshot.elements, screen: snapshot.screen,
                                                                 naming: withAnswer)
                switch answer.inFront(over, of: target) {
                case true?:
                    guard case .overlayCovering(let o)? = after.kind else { XCTFail("\(name) ref \(target.ref): 名指していない"); continue }
                    XCTAssertEqual(o.ref, over.ref); XCTAssertFalse(after.namingSuppressed); named += 1
                case false?:
                    XCTAssertFalse(after.namingSuppressed, "\(name) ref \(target.ref): 奥の覆いの注意が残った")
                    if case .overlayCovering? = after.kind { XCTFail("\(name) ref \(target.ref): 奥の覆いを名指した") }
                    cleared += 1
                case nil:
                    XCTAssertTrue(after.namingSuppressed); kept += 1
                }
            }
        }
        // 段0の3画面の実数。named = 半分のシートの行が本文の行を覆う7組 / cleared = FAB・下のバーとそのボタン・シートの見出しが
        // 手前の9組(DR-230 の名指さない注意が外れていた組)/ kept = identifier の無い要素(対応が取れない)。採り直したら1件ずつ絵で確かめてから直す
        XCTAssertEqual([named, cleared, kept], [Self.expectedNamed, Self.expectedCleared, Self.expectedKept],
                       "named=\(named) cleared=\(cleared) kept=\(kept)")
    }

    static let expectedNamed = 7
    static let expectedCleared = 9
    static let expectedKept = 3
}
