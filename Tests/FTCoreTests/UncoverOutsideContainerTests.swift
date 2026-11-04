// 容器の外のバー(スクロールで隠れる上部バー)が容器の縁に接する名前つきの物に覆われたとき、
// 主たる縦の容器を戻して外す判定の固定。形は E2EY-Flutter「スクロールで隠れるバー」の木。
import XCTest
@testable import FTCore

final class UncoverOutsideContainerTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
    private let list = FTRect(x: 0, y: 174, width: 402, height: 700)

    private func el(_ ref: Int, _ type: String, id: String? = nil, label: String? = nil,
                    _ r: FTRect, scrollable: Bool? = nil) -> ElementInfo {
        var e = ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                            placeholder: nil, enabled: true, frame: r, depth: 2)
        e.scrollable = scrollable
        return e
    }

    func testPrimaryContainerPicksTheBigVerticalScroller() {
        let lane = el(2, "other", FTRect(x: 0, y: 400, width: 402, height: 48), scrollable: true)
        let big = el(3, "other", FTRect(x: 0, y: 174, width: 402, height: 700), scrollable: true)
        XCTAssertEqual(TapTargetGeometry.primaryScrollContainer(in: [lane, big], screen: screen)?.ref, 3)
        XCTAssertNil(TapTargetGeometry.primaryScrollContainer(in: [lane], screen: screen))
    }

    /// 横向きの縦の一覧(実測 RN の iOS の隠れるバー: 一覧 874x272・画面 874x402)も主たる容器。細い横の帯は外れたまま
    func testPrimaryContainerIncludesAWideVerticalListInLandscape() {
        let landscape = FTRect(x: 0, y: 0, width: 874, height: 402)
        let list = el(5, "other", FTRect(x: 0, y: 130, width: 874, height: 272), scrollable: true)
        let lane = el(6, "other", FTRect(x: 0, y: 130, width: 874, height: 48), scrollable: true)
        XCTAssertEqual(TapTargetGeometry.primaryScrollContainer(in: [list, lane], screen: landscape)?.ref, 5)
        XCTAssertNil(TapTargetGeometry.primaryScrollContainer(in: [lane], screen: landscape))
    }

    func testNamedCoverAboveContainerPullsContentDown() {
        let target = el(1, "button", id: "btn_top_action", label: "並べ替え",
                        FTRect(x: 333, y: 100, width: 56, height: 20))
        let cover = el(2, "staticText", label: "受信トレイ", FTRect(x: 16, y: 148, width: 305, height: 26))
        let jump = TapTargetGeometry.uncoverOutsideScrollJump(target: target, coveredBy: cover, container: list)
        XCTAssertLessThan(jump ?? 0, 0, "上の覆いは内容を下へ戻す向き(負)")
    }

    func testCoverNotTouchingTheContainerEdgeIsNil() {
        let target = el(1, "button", label: "x", FTRect(x: 333, y: 100, width: 56, height: 20))
        let cover = el(2, "staticText", label: "受信トレイ", FTRect(x: 16, y: 90, width: 305, height: 26))
        XCTAssertNil(TapTargetGeometry.uncoverOutsideScrollJump(target: target, coveredBy: cover, container: list))
    }

    func testTargetInsideContainerIsLeftToTheOrdinaryLift() {
        let target = el(1, "button", label: "x", FTRect(x: 16, y: 200, width: 340, height: 48))
        let cover = el(2, "staticText", label: "見出し", FTRect(x: 0, y: 148, width: 402, height: 26))
        XCTAssertNil(TapTargetGeometry.uncoverOutsideScrollJump(target: target, coveredBy: cover, container: list))
    }

    func testUnnamedCoverIsNil() {
        let target = el(1, "button", label: "x", FTRect(x: 333, y: 100, width: 56, height: 20))
        let cover = el(2, "other", FTRect(x: 0, y: 148, width: 402, height: 26))
        XCTAssertNil(TapTargetGeometry.uncoverOutsideScrollJump(target: target, coveredBy: cover, container: list))
    }

    /// 形3: 一覧の上に浮いた FAB は、容器の外へはみ出た中身(ghost)ではない。仲間の居る行は ghost のまま
    func testFloatingFabIsNotAGhostButAScrolledOutRowIs() {
        var els: [ElementInfo] = []
        els.append(el(1, "other", FTRect(x: 0, y: 168, width: 402, height: 706), scrollable: true))
        els[0].depth = 1
        var rows: [ElementInfo] = [(2, 200.0), (3, 252.0), (4, -10.0)].map { ref, y in
            var r = el(Int(ref), "button", label: "行", FTRect(x: 8, y: y, width: 386, height: 48)); r.depth = 3; return r }
        // 行は容器(wrapper)の中に並び、FAB は同じ深さで後ろに続く = 木の上では wrapper の兄弟で枠の外
        var wrapper = el(10, "other", FTRect(x: 0, y: 168, width: 402, height: 300)); wrapper.depth = 2
        els.insert(wrapper, at: 1)
        els += rows
        var fab = el(9, "button", id: "fab_hiding", FTRect(x: 330, y: 700, width: 56, height: 56)); fab.depth = 3
        els.append(fab)
        XCTAssertFalse(ContainerGeometry.isOutsideContainer(fab, in: els, screen: screen), "浮いた FAB は送らず撃つ")
        rows = els.filter { $0.ref == 4 }
        XCTAssertTrue(ContainerGeometry.isOutsideContainer(rows[0], in: els, screen: screen), "押し出された行は ghost のまま")
    }

    /// 形3(iOS の RN): FAB を包む Animated.View が木に出ず、深さでたどると直前の上部バー(y=168〜224)が
    /// 親に見える = 容器の外の ghost と読み、一覧を送って FAB を隠していた。実際に撮った木(in-app・E2EY-RN の
    /// 隠れるバーの画面)で、中心を含む申告スクロール容器で代えて浮いた物と読むことを固定する
    func testFloatingFabWhoseWrapperIsMissingFromTheTreeIsNotAGhost() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/E2EYTrees/rn-ios-hide-bars.json")
        let snapshot = try JSONDecoder().decode(SnapshotResponse.self, from: Data(contentsOf: url))
        let fab = try XCTUnwrap(snapshot.elements.first { $0.identifier == "fab_hiding" })
        XCTAssertFalse(ContainerGeometry.isOutsideContainer(fab, in: snapshot.elements, screen: snapshot.screen),
                       "浮いた FAB は送らず撃つ")
        // 行(仲間の居る要素)は浮いた物と読まない = ghost の判定を潰していない
        let row = try XCTUnwrap(snapshot.elements.first { $0.identifier == "row_h_00" })
        XCTAssertFalse(ContainerGeometry.isFloatingOverDeclaredScroller(row, in: snapshot.elements))
    }

    // MARK: 縮んだヘッダの下に潜ったフォロー(E2EY-RN の折りたたみヘッダとタブ・iOS で撮った枠)

    private func collapsedHeaderTree(barBottom: Double = 116) -> [ElementInfo] {
        var list = el(7, "other", FTRect(x: 0, y: 187, width: 402, height: 687), scrollable: true); list.depth = 3
        var follow = el(33, "button", id: "btn_follow", label: "フォロー", FTRect(x: 157, y: 83, width: 88, height: 44)); follow.depth = 3
        var bar = el(34, "navigationBar", id: "折りたたみヘッダとタブ", FTRect(x: 0, y: 62, width: 402, height: barBottom - 62)); bar.depth = 3
        return [list, follow, bar]
    }

    func testTargetUnderABarThatDoesNotTouchTheContainerIsReported() {
        let els = collapsedHeaderTree()
        let over = TapTargetGeometry.coveredOutsideContainerBeyondOneLift(els[1], in: els, screen: screen, inferring: true)
        XCTAssertEqual(over?.identifier, "折りたたみヘッダとタブ")
        XCTAssertNil(TapTargetGeometry.uncoverOutsideScrollJump(target: els[1], coveredBy: els[2], container: els[0].frame),
                     "既存の1回の送りでは出せない形")
    }

    /// 容器の縁に接する覆いは既存の送り(liftCoveredTarget)の領分 = ここでは拾わない
    func testBarTouchingTheContainerEdgeIsLeftToTheOrdinaryLift() {
        let els = collapsedHeaderTree(barBottom: 187)
        XCTAssertNil(TapTargetGeometry.coveredOutsideContainerBeyondOneLift(els[1], in: els, screen: screen, inferring: true))
    }

    func testUncoveredTargetIsNotReported() {
        var els = collapsedHeaderTree()
        els[1].frame = FTRect(x: 157, y: 130, width: 88, height: 44)
        XCTAssertNil(TapTargetGeometry.coveredOutsideContainerBeyondOneLift(els[1], in: els, screen: screen, inferring: true))
    }

    /// `scroll:` を書いていない tap も、この形の対象には撃たずに断り、送る向きを `scroll:` で案内する(RN の iOS の A10:
    /// 覆いの下と注記しながら撃って、縮んだヘッダの中身に当たり何も起きないまま ok だった)
    func testTapWithoutScrollRefusesATargetBuriedUnderTheBar() async {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [collapsedHeaderTree()])
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables(defaultTimeout: 0.2))
        let outcome = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn_follow")))
        guard case .failed(let message) = outcome.status else { return XCTFail("断るはず: \(outcome.status)") }
        XCTAssertTrue(message.contains("Add scroll: .up") && message.contains("nothing was touched"), message)
        XCTAssertFalse(log.entries.contains { $0.contains(".tap(") || $0.contains(".press(") }, "撃った: \(log.entries)")
        XCTAssertTrue(primary.coordinateTaps.isEmpty)
    }

    /// `scroll:` を持たない操作(doubleTap)には、書けない `Add scroll:` を案内せず先に送る手を案内する
    func testDoubleTapRefusalSuggestsScrollingFirstInsteadOfAnArgument() async {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [collapsedHeaderTree()])
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables(defaultTimeout: 0.2))
        let outcome = await executor.execute(FlowStep(action: "doubleTap", locator: FlowLocator(id: "btn_follow")))
        guard case .failed(let message) = outcome.status else { return XCTFail("断るはず: \(outcome.status)") }
        XCTAssertFalse(message.contains("Add scroll:"), message)
        XCTAssertTrue(message.contains("scrollUp()") && message.contains("nothing was touched"), message)
    }

    /// 隠れるバー(RN の iOS・in-app で撮った枠): 対象はバー自身を容器と推定されるが、その容器は一覧と交わらない =
    /// 外の対象。中心がナビゲーションバーの下で撃つと何も起きないまま ok だった(hide= が変わらない)
    func testTargetInsideAHiddenBarOutsideTheListIsReported() {
        var list = el(5, "other", FTRect(x: 0, y: 168, width: 402, height: 706), scrollable: true); list.depth = 2
        var rowA = el(10, "button", id: "row_h_22", label: "行 H22", FTRect(x: 8, y: 170, width: 386, height: 48)); rowA.depth = 3
        var rowB = el(11, "button", id: "row_h_23", label: "行 H23", FTRect(x: 8, y: 222, width: 386, height: 48)); rowB.depth = 3
        var bar = el(24, "other", id: "bar_top_hiding", FTRect(x: 0, y: 84, width: 402, height: 56)); bar.depth = 2
        var title = el(25, "staticText", label: "受信トレイ", FTRect(x: 12, y: 101, width: 84, height: 21)); title.depth = 3
        var action = el(27, "button", id: "btn_top_action", label: "並べ替え", FTRect(x: 301, y: 90, width: 88, height: 44)); action.depth = 3
        var nav = el(28, "navigationBar", id: "スクロールで隠れるバー", FTRect(x: 0, y: 62, width: 402, height: 54)); nav.depth = 2
        let els = [list, rowA, rowB, bar, title, action, nav]
        XCTAssertNotNil(ContainerGeometry.clippingContainer(of: action, in: els, inferring: true), "前提: バー自身が容器と推定される形")
        XCTAssertEqual(TapTargetGeometry.coveredOutsideContainerBeyondOneLift(action, in: els, screen: screen, inferring: true)?.identifier,
                       "スクロールで隠れるバー")
        // 一覧の中の行は対象にしない
        XCTAssertNil(TapTargetGeometry.coveredOutsideContainerBeyondOneLift(rowA, in: els, screen: screen, inferring: true))
        // 一覧の上縁をまたぐ行(推定の容器 = 一覧と交わる)は、中心が一覧の外で名前つきの帯の下でも見切れの回収の領分。
        // 完全に外の行は ghost として覆いの判定より前に外れるので、縁をまたぐ形で組む
        var wrapper = el(6, "other", FTRect(x: 0, y: 168, width: 402, height: 706)); wrapper.depth = 2
        var straddle = el(9, "button", id: "row_h_21", label: "行 H21", FTRect(x: 8, y: 130, width: 386, height: 60)); straddle.depth = 3
        var band = el(29, "staticText", label: "見出し", FTRect(x: 0, y: 140, width: 402, height: 24)); band.depth = 2
        let withStraddle = [list, wrapper, straddle, rowA, rowB, band]
        XCTAssertNotNil(ContainerGeometry.clippingContainer(of: straddle, in: withStraddle, inferring: true), "前提: 容器が推定される")
        XCTAssertNotNil(TapTargetGeometry.overlayCoveringForUncover(straddle, in: withStraddle, screen: screen), "前提: 帯が中心を覆う")
        XCTAssertNil(TapTargetGeometry.coveredOutsideContainerBeyondOneLift(straddle, in: withStraddle, screen: screen, inferring: true))
    }

    // MARK: 横向きの隠れるバー(E2EY-RN の iOS・横向きで撮った枠。10周目の探索 iultra F6)

    /// 偽のドライバの横向きの画面(800x400)に合わせて幅だけ詰めた
    private func landscapeHiddenBarTree() -> [ElementInfo] {
        var list = el(5, "other", FTRect(x: 0, y: 130, width: 800, height: 272), scrollable: true); list.depth = 2
        var row = el(8, "button", id: "row_h_34", label: "行 H34", FTRect(x: 8, y: 105, width: 784, height: 48)); row.depth = 3
        var row2 = el(9, "button", id: "row_h_35", label: "行 H35", FTRect(x: 8, y: 157, width: 784, height: 48)); row2.depth = 3
        var bar = el(14, "other", id: "bar_top_hiding", FTRect(x: 0, y: 46, width: 800, height: 56)); bar.depth = 2
        var title = el(15, "staticText", label: "受信トレイ", FTRect(x: 12, y: 63, width: 84, height: 21)); title.depth = 3
        var action = el(17, "button", id: "btn_top_action", label: "並べ替え", FTRect(x: 700, y: 52, width: 88, height: 44)); action.depth = 3
        var nav = el(18, "navigationBar", id: "スクロールで隠れるバー", FTRect(x: 0, y: 24, width: 800, height: 54)); nav.depth = 2
        return [list, row, row2, bar, title, action, nav]
    }

    /// 横向きの tap も撃たずに断る(縦向きと同じ)。横長の一覧が主たる容器に入らず、断りを素通りして何も押さずに ok だった
    func testLandscapeTapUnderTheBarIsRefused() async {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [landscapeHiddenBarTree()])
        primary.screenOrientation = .landscape
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables(defaultTimeout: 0.2))
        let outcome = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn_top_action")))
        guard case .failed(let message) = outcome.status else { return XCTFail("断るはず: \(outcome.status) / \(outcome.driverFallback ?? "") / \(log.entries)") }
        XCTAssertTrue(message.contains("Add scroll: .up"), message)
        XCTAssertFalse(log.entries.contains { $0.contains(".tap(") || $0.contains(".press(") }, "撃った: \(log.entries)")
    }

    // MARK: 入れ子のスクロール(E2EY-RN の入れ子スクロール・10周目の探索 ilocal F2)

    private func nestedTree(shelfY: Double) -> [ElementInfo] {
        var outer = el(1, "other", id: "list_nested", FTRect(x: 0, y: 157, width: 400, height: 600), scrollable: true); outer.depth = 1
        var shelf = el(2, "other", id: "shelf_2", FTRect(x: 0, y: shelfY, width: 400, height: 130), scrollable: true); shelf.depth = 2
        var a = el(3, "button", id: "card_2_00", label: "カード 2-00", FTRect(x: 16, y: shelfY + 5, width: 140, height: 120)); a.depth = 3
        var b = el(4, "button", id: "card_2_01", label: "カード 2-01", FTRect(x: 164, y: shelfY + 5, width: 140, height: 120)); b.depth = 3
        var row = el(5, "button", id: "row_n_00", label: "行", FTRect(x: 0, y: 400, width: 400, height: 48)); row.depth = 2
        return [outer, shelf, a, b, row]
    }

    /// 外側の一覧の上へはみ出した棚の中のカードは、撃たずに断って外側を送る向きを案内する
    func testCardClippedByTheOuterListIsRefused() async {
        let els = nestedTree(shelfY: -55)
        XCTAssertEqual(TapTargetGeometry.clippedByOuterScroller(els[2], in: els, scale: 1)?.identifier, "list_nested")
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [els])
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables(defaultTimeout: 0.2))
        let outcome = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "card_2_00")))
        guard case .failed(let message) = outcome.status else { return XCTFail("断るはず: \(outcome.status)") }
        XCTAssertTrue(message.contains("outer scrolling list") && message.contains("Add scroll: .up"), message)
        XCTAssertFalse(log.entries.contains { $0.contains(".tap(") || $0.contains(".press(") }, "撃った: \(log.entries)")
    }

    /// 外側の一覧の中に収まった棚のカードは対象外(従来どおり押す)
    func testCardInsideTheOuterListIsNotRefused() {
        let els = nestedTree(shelfY: 200)
        XCTAssertNil(TapTargetGeometry.clippedByOuterScroller(els[2], in: els, scale: 1))
        XCTAssertNil(TapTargetGeometry.clippedByOuterScroller(els[4], in: els, scale: 1), "棚の外の行(容器が1段)も対象外")
        // 棚(最も内側の容器)の縁でほぼ切れていても、外側の一覧の中なら対象外(棚の見切れは従来の判定の領分)
        var shelf = el(2, "other", id: "shelf_2", FTRect(x: 0, y: 200, width: 300, height: 130), scrollable: true); shelf.depth = 2
        var edgeCard = el(3, "button", id: "card_2_02", FTRect(x: 296, y: 205, width: 140, height: 120)); edgeCard.depth = 3
        var mate = el(4, "button", id: "card_2_01", FTRect(x: 150, y: 205, width: 140, height: 120)); mate.depth = 3
        var mate2 = el(6, "button", id: "card_2_00", FTRect(x: 4, y: 205, width: 140, height: 120)); mate2.depth = 3
        let edge = [els[0], shelf, mate2, mate, edgeCard]
        XCTAssertNil(TapTargetGeometry.clippedByOuterScroller(edgeCard, in: edge, scale: 1))
    }

    /// 見つからない tap(向き無し・送れる一覧あり)には scroll: の案内も足す。向きを書いた回・一覧の無い画面では足さない
    func testNotFoundTapSuggestsScrollWhenAListCanBeScrolled() {
        let withList = SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [el(1, "other", FTRect(x: 0, y: 174, width: 402, height: 700), scrollable: true)], truncatedCount: 0)
        let bare = SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [], truncatedCount: 0)
        XCTAssertTrue(StepExecutor.scrollOffHint(FlowStep(action: "tap"), in: withList).contains("scroll: .up"))
        XCTAssertEqual(StepExecutor.scrollOffHint(FlowStep(action: "tap", direction: "down"), in: withList), "")
        XCTAssertEqual(StepExecutor.scrollOffHint(FlowStep(action: "tap"), in: bare), "")
        XCTAssertEqual(StepExecutor.scrollOffHint(FlowStep(action: "doubleTap"), in: withList), "", "scroll: を持たない操作には書かない")
    }

    // MARK: 送れば外れる側の縁のバーの下(10周目の探索 im4 F1・F2)

    func testEdgeBarCoveringCentreLooksAtTheBarTheSearchMovesAwayFrom() {
        var nav = el(1, "navigationBar", id: "nav", FTRect(x: 0, y: 0, width: 402, height: 116)); nav.depth = 1
        var back = el(2, "button", id: "BackButton", FTRect(x: 16, y: 62, width: 44, height: 44)); back.depth = 2
        var field = el(3, "textField", id: "field_password", FTRect(x: 16, y: 80, width: 370, height: 33)); field.depth = 1
        nav.ref = 4; field.ref = 3   // 塗り順: バーが後 = 手前
        let els = [field, nav, back]
        XCTAssertNotNil(TapTargetGeometry.edgeBarCoveringCentre(field, in: els, screen: screen, safeAreaTop: .unknown, finger: .down),
                        "上を見に行く探索(指が下)はナビゲーションバーの下を見つかったにしない")
        XCTAssertNil(TapTargetGeometry.edgeBarCoveringCentre(field, in: els, screen: screen, safeAreaTop: .unknown, finger: .up),
                     "下を見に行く探索では上のバーは外れない側")
        XCTAssertNil(TapTargetGeometry.edgeBarCoveringCentre(back, in: els, screen: screen, safeAreaTop: .unknown, finger: .down),
                     "バー自身の子孫は対象外")
        var inBand = el(5, "textField", id: "field_band", FTRect(x: 16, y: 6, width: 370, height: 33)); inBand.depth = 1
        XCTAssertEqual(TapTargetGeometry.edgeBarCoveringCentre(inBand, in: [inBand], screen: screen, safeAreaTop: .measured(62),
                                                               finger: .down), "the top safe-area band")
    }

    /// 探索の「見つかった」ゲートがこの判定を通っていること(外すと覆いの下のまま撃って緑になる)
    func testScrollSearchFoundGateConsultsTheCoverCheck() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let search = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/StepExecutor+ScrollSearch.swift"), encoding: .utf8)
        let settle = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/StepExecutor+Settle.swift"), encoding: .utf8)
        XCTAssertTrue(search.contains("let buriedUnderBar = buriedUnderBarForTouch(element, step: step, in: snapshot)"), "本編")
        XCTAssertTrue(settle.contains("!buriedUnderBarForTouch(element, step: step, in: snapshot)"), "逆走査も同じ判定を通る")
    }
}
