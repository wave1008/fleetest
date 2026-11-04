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

    /// 探索の「見つかった」ゲートがこの判定を通っていること(外すと覆いの下のまま撃って緑になる)
    func testScrollSearchFoundGateConsultsTheCoverCheck() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let search = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/StepExecutor+ScrollSearch.swift"), encoding: .utf8)
        let settle = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/StepExecutor+Settle.swift"), encoding: .utf8)
        XCTAssertTrue(search.contains("let buriedUnderBar = buriedUnderBarForTouch(element, step: step, in: snapshot)"), "本編")
        XCTAssertTrue(settle.contains("!buriedUnderBarForTouch(element, step: step, in: snapshot)"), "逆走査も同じ判定を通る")
    }
}
