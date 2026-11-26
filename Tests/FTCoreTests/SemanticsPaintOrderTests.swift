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

/// 実行機の上の配線(DR-235): 検証の V3 で、覆いが塗り順で手前なら注記を立てる・名指せる組や覆いの無い要素では聞かない
final class SemanticsPaintOrderExecutorTests: XCTestCase {
    private func el(_ ref: Int, _ id: String, y: Double, height: Double = 100) -> ElementInfo {
        ElementInfo(ref: ref, type: "button", identifier: id, label: id, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 0, y: y, width: 400, height: height), depth: 1)
    }
    private let screen = FTRect(x: 0, y: 0, width: 400, height: 800)

    private func executor(answerFront front: ElementInfo, back: ElementInfo, framework: AppUIFramework) -> (StepExecutor, FakeAppDriver) {
        let driver = FakeAppDriver(name: "p", log: CallLog())
        driver.semanticsOrderAnswer = SemanticsOrderResponse(
            dump: "SemanticsNode#0\n ├─SemanticsNode#\(back.ref + 10)\n └─SemanticsNode#\(front.ref + 10)\n",
            nodes: [front, back].map { .init(ref: $0.ref, semanticsId: $0.ref + 10, cx: $0.frame.centerX, cy: $0.frame.centerY) },
            reason: nil)
        let executor = StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables(), uiFramework: framework)
        return (executor, driver)
    }

    private func evidence(_ target: ElementInfo, _ elements: [ElementInfo]) -> VisibilityEvidence {
        VisibilityEvidence(element: target, expectedText: target.label ?? "", elements: elements, screen: screen,
                           keyboardShown: false, looseMatch: false, expectedIsUserText: false, perStepGuard: nil)
    }

    func testCoverInFrontOnFlutterIsReported() async {
        let row = el(1, "row", y: 300), sheet = el(2, "sheet_row", y: 320)
        let (executor, driver) = executor(answerFront: sheet, back: row, framework: .flutter)
        let covered = await executor.coveredInPaintRanks(evidence(row, [row, sheet]))
        XCTAssertTrue(covered)
        XCTAssertEqual(driver.semanticsOrderCalls, 1)
        let again = await executor.coveredInPaintRanks(evidence(row, [row, sheet]))
        XCTAssertTrue(again)
        XCTAssertEqual(driver.semanticsOrderCalls, 1, "同じ木で2回聞かない")
        executor.noteAppLaunched(bundleID: "com.example.flutter")
        XCTAssertNil(executor.paintRanksCache, "起こし直したら塗り順の控えも捨てる")
        XCTAssertNil(executor.semanticsOrderCache)
    }

    func testAnswerForAnotherTreeIsDroppedButNotRemembered() async {
        let row = el(1, "row", y: 300), sheet = el(2, "sheet_row", y: 320)
        let (executor, driver) = executor(answerFront: sheet, back: row, framework: .flutter)
        let moved = el(2, "sheet_row", y: 340)
        let stale = await executor.coveredInPaintRanks(evidence(row, [row, moved]))
        XCTAssertFalse(stale, "答えの中心がこの木と合わない = 捨てる")
        _ = await executor.coveredInPaintRanks(evidence(row, [row, moved]))
        XCTAssertEqual(driver.semanticsOrderCalls, 2, "食い違った答えは控えない = 同じ内容の木を次に撮れば聞き直す")
        XCTAssertNil(executor.paintRanksCache, "木の食い違いは塗り順の控えに残さない")
        XCTAssertEqual(StepExecutor.unavailableReason(driver.semanticsOrderAnswer), "unusable-answer")
        XCTAssertEqual(StepExecutor.unavailableReason(nil), "no-response")
    }

    func testCoverBehindOrNameablePairIsNotReportedAndNotAsked() async {
        let row = el(1, "row", y: 300), sheet = el(2, "sheet_row", y: 320)
        let (behind, _) = executor(answerFront: row, back: sheet, framework: .flutter)
        let notCovered = await behind.coveredInPaintRanks(evidence(row, [row, sheet]))
        XCTAssertFalse(notCovered, "覆いが奥なら言わない")
        let (compose, composeDriver) = executor(answerFront: sheet, back: row, framework: .compose)
        let composeCovered = await compose.coveredInPaintRanks(evidence(row, [row, sheet]))
        XCTAssertFalse(composeCovered)
        XCTAssertEqual(composeDriver.semanticsOrderCalls, 0, "名指せる組(塗り順のある木の側)では聞かない")
        let far = el(3, "far", y: 600)
        let (alone, aloneDriver) = executor(answerFront: sheet, back: row, framework: .flutter)
        let aloneCovered = await alone.coveredInPaintRanks(evidence(far, [row, sheet, far]))
        XCTAssertFalse(aloneCovered)
        XCTAssertEqual(aloneDriver.semanticsOrderCalls, 0, "覆いの無い要素では聞かない")
    }
}

/// OI-200 ①(DR-235): Android の Flutter のダイアログの間の否定の検証に注記。材料はダンプのダイアログの役割だけ
final class FlutterDialogAbsenceTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/FlutterSemanticsOrder")

    func testOnlyTheDialogDumpPresentsADialog() throws {
        func dump(_ name: String) throws -> String {
            try String(contentsOf: Self.fixtures.appendingPathComponent("\(name)-dump.txt"), encoding: .utf8)
        }
        XCTAssertTrue(FlutterSemanticsDump.presentsDialog(dump: try dump("dialog")), "破棄の確認ダイアログ(role: alertDialog)")
        for name in ["half", "fab", "hide"] {
            XCTAssertFalse(FlutterSemanticsDump.presentsDialog(dump: try dump(name)), "\(name): シート・FAB・バーはダイアログではない")
        }
    }

    /// 下の `snapshot` の要素(枠 0,0 100x50)に、ダンプの「編集を続ける」のボタン(SemanticsNode#95)を対応させた答えの節
    private static let keepButtonNode: [SemanticsOrderResponse.Node] = [.init(ref: 1, semanticsId: 95, cx: 50, cy: 25)]

    private func snapshot(renderer: String?, app: String = "com.example.flutter", label: String = "編集を続ける") -> SnapshotResponse {
        var e = ElementInfo(ref: 1, type: "button", identifier: "btn_keep", label: label, value: nil, placeholder: nil,
                            enabled: true, frame: FTRect(x: 0, y: 0, width: 100, height: 50), depth: 1)
        e.renderer = renderer
        return SnapshotResponse(sessionBundleID: app, screen: FTRect(x: 0, y: 0, width: 400, height: 800), elements: [e], truncatedCount: 0)
    }

    func testNoteFollowsTheDumpAndIsNotAskedOutsideVirtualTrees() async throws {
        let dialog = try String(contentsOf: Self.fixtures.appendingPathComponent("dialog-dump.txt"), encoding: .utf8)
        let driver = FakeAppDriver(name: "p", log: CallLog())
        driver.semanticsOrderAnswer = SemanticsOrderResponse(dump: dialog, nodes: Self.keepButtonNode, reason: nil)
        let executor = StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())
        await executor.noteAbsenceBehindModal(snapshot(renderer: "virtual"))
        XCTAssertTrue(executor.noteCodesThisStep.contains(.absenceBehindFlutterDialog))

        let otherTree = FakeAppDriver(name: "p", log: CallLog())
        otherTree.semanticsOrderAnswer = SemanticsOrderResponse(
            dump: dialog, nodes: [.init(ref: 1, semanticsId: 95, cx: 50, cy: 400)], reason: nil)
        let otherExecutor = StepExecutor(driver: otherTree, isAndroid: true, tunables: RunTunables())
        await otherExecutor.noteAbsenceBehindModal(snapshot(renderer: "virtual"))
        XCTAssertFalse(otherExecutor.noteCodesThisStep.contains(.absenceBehindFlutterDialog),
                       "答えがこの木のものでなければダンプを信じない(後から開いたダイアログ)")

        let viewDriver = FakeAppDriver(name: "p", log: CallLog())
        viewDriver.semanticsOrderAnswer = SemanticsOrderResponse(dump: dialog, nodes: Self.keepButtonNode, reason: nil)
        let viewExecutor = StepExecutor(driver: viewDriver, isAndroid: true, tunables: RunTunables())
        await viewExecutor.noteAbsenceBehindModal(snapshot(renderer: "view"))
        XCTAssertFalse(viewExecutor.noteCodesThisStep.contains(.absenceBehindFlutterDialog))
        XCTAssertEqual(viewDriver.semanticsOrderCalls, 0, "仮想の要素の無い木では聞かない")
    }

    func testMissingVMServiceIsRememberedForTheScenario() async {
        let driver = FakeAppDriver(name: "p", log: CallLog())
        driver.semanticsOrderAnswer = SemanticsOrderResponse(dump: nil, nodes: nil, reason: "no-vm-service")
        let executor = StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())
        await executor.noteAbsenceBehindModal(snapshot(renderer: "virtual"))
        await executor.noteAbsenceBehindModal(snapshot(renderer: "virtual", label: "別の木"))
        XCTAssertEqual(driver.semanticsOrderCalls, 1, "VM サービスが無いと答えたアプリへ聞き直さない(木が変わっても)")
        XCTAssertFalse(executor.noteCodesThisStep.contains(.absenceBehindFlutterDialog))
        executor.noteAppLaunched(bundleID: "com.example.flutter")
        await executor.noteAbsenceBehindModal(snapshot(renderer: "virtual"))
        XCTAssertEqual(driver.semanticsOrderCalls, 2, "起こし直したアプリ(新しい pid)には聞き直す")
        await executor.noteAbsenceBehindModal(snapshot(renderer: "virtual", app: "com.example.other", label: "4つ目"))
        XCTAssertEqual(driver.semanticsOrderCalls, 3, "別のアプリには聞く")
    }

    func testScopedAbsenceInsideTheDialogIsNotNoted() async throws {
        let dialog = try String(contentsOf: Self.fixtures.appendingPathComponent("dialog-dump.txt"), encoding: .utf8)
        let driver = FakeAppDriver(name: "p", log: CallLog())
        driver.semanticsOrderAnswer = SemanticsOrderResponse(dump: dialog, nodes: Self.keepButtonNode, reason: nil)
        let executor = StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())
        let step = FlowStep(assert: "notExists", locator: FlowLocator(id: "no_such", scope: [FlowLocator(id: "btn_keep")]))
        await executor.noteAbsenceBehindModal(snapshot(renderer: "virtual"), step: step)
        XCTAssertFalse(executor.noteCodesThisStep.contains(.absenceBehindFlutterDialog), "容器が木に在る = ダイアログの中の本物の不在")
    }
}


/// ブリッジとホストで同期する語彙と、上限の既定値(DR-4)。Java の側はソースを読んで比べる
final class SemanticsOrderWireSyncTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    func testReasonSpellingMatchesTheBridge() throws {
        let java = try source("AndroidRunner/src/com/example/ftbridge/FlutterSemanticsOrder.java")
        XCTAssertTrue(java.contains("REASON_NO_VM_SERVICE = \"\(StepExecutor.noVMServiceReason)\""),
                      "控えの鍵の語(no-vm-service)がブリッジと割れた = 控えが黙って効かなくなる")
    }

    func testBudgetsArePinned() throws {
        XCTAssertEqual(PaintRankAnswer.centreTolerance, 1.0)
        let java = try source("AndroidRunner/src/com/example/ftbridge/FlutterSemanticsOrder.java")
        XCTAssertTrue(java.contains("HTTP_TIMEOUT_MS = 500;"))
        XCTAssertTrue(java.contains("ANSWER_BUDGET_MS = 1500;"))
        let client = try source("Sources/FTBridgeClient/BridgeClient.swift")
        XCTAssertTrue(client.contains("static let semanticsOrderTimeout: TimeInterval = 5"),
                      "ホストの上限はブリッジの答え全体の上限(1.5 秒)より長いこと")
    }
}
