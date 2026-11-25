// 上端の帯の中心の撃つ点を帯の下の見えている部分へ寄せることと、塗り順の木の祖先の数え方(塗り順が本物の木では z が大きい候補を祖先と数えない)の
// MCP 側の配線。判定は FTCore(`TapTargetGeometry.topBandTapY` / `OcclusionGeometry`)で DSL と共有、文言だけ MCP。
// 木は OI389ScrimAncestorTests と同じ(RN の Android のボトムシートの幕)。

import XCTest
@testable import FTCore
@testable import fleetest_mcp

final class OI388OI389MCPParityTests: XCTestCase {
    private let phone = FTRect(x: 0, y: 0, width: 402, height: 874)
    private let screen = FTRect(x: 0, y: 0, width: 1280, height: 2856)

    private func straddler() -> ElementInfo {
        ElementInfo(ref: 1, type: "button", identifier: "btn_top", label: "Top", value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 20, y: 30, width: 100, height: 50), depth: 2)
    }

    private func server(safeAreaTop: SafeAreaTop, element: ElementInfo) -> MCPServer {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() }, recordSnapshot: { _, _, _ in })
        server.lastSnapshots[MCPServer.sessionKey([:])] = SnapshotResponse(
            sessionBundleID: "com.example.app", screen: phone, elements: [element], truncatedCount: 0,
            safeAreaTop: safeAreaTop)
        return server
    }

    func testBandStraddlingElementIsTouchedBelowTheBand() async {
        let el = straddler()
        let s = server(safeAreaTop: .measured(62), element: el)
        let point = await s.bottomBandPoint(frame: el.frame, driver: FakeDriver(), args: [:])
        let expected = TapTargetGeometry.topBandTapY(for: el.frame, safeAreaTop: .measured(62), screen: phone)
        XCTAssertNotNil(expected)
        XCTAssertEqual(point?.y, expected)
        XCTAssertGreaterThan(point?.y ?? 0, 62, "帯の外")
        XCTAssertEqual(point?.note, MCPServer.topBandTouchNote)
    }

    func testUnknownSafeAreaDoesNotMoveThePoint() async {
        let el = straddler()
        let s = server(safeAreaTop: .unknown, element: el)
        let point = await s.bottomBandPoint(frame: el.frame, driver: FakeDriver(), args: [:])
        XCTAssertNil(point)
    }

    func testWarningIsSilentOnlyWhereTheTouchIsMoved() {
        let el = straddler()
        XCTAssertNil(RefGuard.topSafeAreaWarning(el, safeAreaTop: .measured(62), screen: phone, clearsTopBand: true))
        XCTAssertNotNil(RefGuard.topSafeAreaWarning(el, safeAreaTop: .measured(62), screen: phone, clearsTopBand: false))
        for op in ["tap", "long press", "double tap"] { XCTAssertTrue(MCPServer.operationClearsTopBand(op), op) }
        for op in ["drag", "pinch", "type"] { XCTAssertFalse(MCPServer.operationClearsTopBand(op), op) }
    }

    /// 寄せない枝(linkText・覆いの外の点・見えている部分)は、消えていた帯の警告を言い直す。寄せられない要素は二重に言わない
    func testBranchesThatDoNotMoveThePointSayTheWarningAgain() {
        let el = straddler()
        let again = RefGuard.suppressedTopBandWarning(el, safeAreaTop: .measured(62), screen: phone)
        XCTAssertNotNil(again, "linkText の tap などは帯の中を撃つので警告が残る")
        XCTAssertEqual(again, RefGuard.topSafeAreaWarning(el, safeAreaTop: .measured(62), screen: phone, clearsTopBand: false))
        let inside = ElementInfo(ref: 1, type: "link", identifier: nil, label: "Back", value: nil, placeholder: nil,
                                 enabled: true, frame: FTRect(x: 16, y: 10, width: 85, height: 20), depth: 2)
        XCTAssertNil(RefGuard.suppressedTopBandWarning(inside, safeAreaTop: .measured(62), screen: phone),
                     "寄せられない要素の警告は preTapWarnings が言っている")
        XCTAssertNil(RefGuard.suppressedTopBandWarning(el, safeAreaTop: .unknown, screen: phone))
    }

    func testBandThatLeavesNothingBelowStillWarns() {
        // 帯の下に見える部分が無い(全部が帯の中)なら寄せられない = 警告のまま
        let el = ElementInfo(ref: 1, type: "link", identifier: nil, label: "Back", value: nil, placeholder: nil,
                             enabled: true, frame: FTRect(x: 16, y: 10, width: 85, height: 20), depth: 2)
        XCTAssertNotNil(RefGuard.topSafeAreaWarning(el, safeAreaTop: .measured(62), screen: phone, clearsTopBand: true))
    }

    // MARK: 幕を祖先と数えない

    private func node(_ ref: Int, _ depth: Int, _ z: Int, _ type: String, _ id: String?, _ label: String?,
                      _ x: Double, _ y: Double, _ w: Double, _ h: Double, scrollable: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: x, y: y, width: w, height: h), depth: depth,
                    scrollable: scrollable, z: z, renderer: "view")
    }

    private var scrimTree: [ElementInfo] {
        [node(1, 11, 23, "button", nil, "Bottom sheet backdrop", 0, 0, 1280, 2856),
         node(2, 14, 28, "scrollView", "list_sheet", nil, 0, 1214, 1280, 1642, scrollable: true),
         node(4, 17, 32, "button", "btn_sheet_opt_1", "選択肢 1", 0, 1284, 1280, 132),
         node(28, 15, 20, "button", nil, "前に戻る", 0, 156, 168, 168),
         node(30, 15, 15, "button", "btn_open_sheet", "シートを開く", 48, 372, 1184, 132),
         node(32, 15, 17, "staticText", "txt_sheet_result", "sheet=none", 48, 528, 1184, 57)]
    }

    func testOverlapWarningNamesTheScrimWhenPaintOrderIsReal() {
        let tree = scrimTree
        let text = RefGuard.overlapWarning(found: tree[4], in: tree, screen: screen,
                                           isAndroid: true, framework: .reactNative, operation: "tap")
        XCTAssertTrue(text.contains("Bottom sheet backdrop"), text)
    }

    func testOverlapWarningDoesNotNameTheScrimWhenPaintOrderIsNotReal() {
        let tree = scrimTree
        let text = RefGuard.overlapWarning(found: tree[4], in: tree, screen: screen,
                                           isAndroid: true, framework: .compose, operation: "tap")
        XCTAssertFalse(text.contains("Bottom sheet backdrop"), text)
    }

    func testRefGuardOverlayCoveringForwardsTheFlag() {
        let tree = scrimTree
        XCTAssertNil(RefGuard.overlayCovering(tree[4], in: tree, screen: screen, paintOrderIsReal: false))
        XCTAssertEqual(RefGuard.overlayCovering(tree[4], in: tree, screen: screen, paintOrderIsReal: true)?.ref, 1)
    }

    func testCaptureRefusalNamesTheScrimOnRealPaintOrder() {
        let tree = scrimTree
        let refusal = MCPServer.captureCoverRefusal(tree[4], in: tree, screen: screen,
                                                    naming: OccluderNamingContext(isAndroid: true, framework: .reactNative))
        XCTAssertTrue(refusal?.contains("Bottom sheet backdrop") == true, refusal ?? "nil")
    }
}
