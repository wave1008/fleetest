// MCP の注記も DSL と同じく、Android の Flutter の同じウィンドウの組は覆いの相手を名指さず、名前の無い注意だけ出す(DR-230)
import XCTest
import FTCore
@testable import fleetest_mcp

final class OccluderNamingMCPTests: XCTestCase {
    func testFlutterGetsAnUnnamedCautionAndOthersKeepTheName() {
        let target = ElementInfo(ref: 1, type: "button", identifier: "fab_extended", label: "追加", value: nil,
                                 placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 300, width: 400, height: 60), depth: 1)
        let row = ElementInfo(ref: 2, type: "button", identifier: "row_f_10", label: "行 10", value: nil,
                              placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 320, width: 400, height: 60), depth: 1)
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        let flutter = RefGuard.overlapWarning(found: target, in: [target, row], screen: screen,
                                              isAndroid: true, framework: .flutter, operation: "tap")
        XCTAssertFalse(flutter.contains("row_f_10"), flutter)
        XCTAssertTrue(flutter.contains("may be covered by another element"), flutter)
        let compose = RefGuard.overlapWarning(found: target, in: [target, row], screen: screen,
                                              isAndroid: true, framework: .compose, operation: "tap")
        XCTAssertTrue(compose.contains("row_f_10"), compose)
        XCTAssertFalse(compose.contains("may be covered by another element"), compose)
    }

    /// DR-235: 塗り順の答えがあれば、覆いが手前なら名指し・奥なら注意を出さない。見本の断りも奥なら出さない
    func testPaintRanksDecideTheFlutterPair() throws {
        let target = ElementInfo(ref: 1, type: "button", identifier: "fab_extended", label: "追加", value: nil,
                                 placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 300, width: 400, height: 60), depth: 1)
        let row = ElementInfo(ref: 2, type: "button", identifier: "row_f_10", label: "行 10", value: nil,
                              placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 320, width: 400, height: 60), depth: 1)
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        let tree = SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [target, row], truncatedCount: 0)
        func ranks(front: ElementInfo, back: ElementInfo) throws -> PaintRankAnswer {
            try XCTUnwrap(PaintRankAnswer.make(response: SemanticsOrderResponse(
                dump: "SemanticsNode#0\n ├─SemanticsNode#\(back.ref + 10)\n └─SemanticsNode#\(front.ref + 10)\n",
                nodes: [front, back].map { .init(ref: $0.ref, semanticsId: $0.ref + 10, cx: $0.frame.centerX, cy: $0.frame.centerY) },
                reason: nil), elements: [target, row]))
        }
        let base = OccluderNamingContext(isAndroid: true, framework: .flutter, paintRanks: nil)
        XCTAssertTrue(MCPServer.namingSuppressed(for: target, in: tree, naming: base), "前提: 答えが無ければ名指せない組")
        XCTAssertFalse(MCPServer.namingSuppressed(for: target, in: tree,
                                                  naming: OccluderNamingContext(isAndroid: true, framework: .compose, paintRanks: nil)),
                       "名指せる組では聞かない")

        let rowInFront = OccluderNamingContext(isAndroid: true, framework: .flutter, paintRanks: try ranks(front: row, back: target))
        let named = RefGuard.overlapWarning(found: target, in: tree.elements, screen: screen, naming: rowInFront, operation: "tap")
        XCTAssertTrue(named.contains("row_f_10"), named)
        XCTAssertFalse(named.contains("may be covered by another element"), named)

        let targetInFront = OccluderNamingContext(isAndroid: true, framework: .flutter, paintRanks: try ranks(front: target, back: row))
        XCTAssertEqual(RefGuard.overlapWarning(found: target, in: tree.elements, screen: screen, naming: targetInFront, operation: "tap"), "",
                       "奥の行は覆いではない")
        XCTAssertNil(MCPServer.captureCoverRefusal(target, in: tree.elements, screen: screen, naming: targetInFront))
        XCTAssertNotNil(MCPServer.captureCoverRefusal(target, in: tree.elements, screen: screen, naming: base), "答えが無ければ断る(今のまま)")
    }

    /// MCP の木の ref はブリッジの ref + 世代の基点(`nativeRef`)。答えの ref を写さないと全部が「木に無い」になり、答えごと捨てられる
    func testBridgeRefsAreShiftedIntoSessionRefs() {
        func el(_ ref: Int, y: Double) -> ElementInfo {
            ElementInfo(ref: ref, type: "button", identifier: "e\(ref)", label: nil, value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 0, y: y, width: 100, height: 100), depth: 0)
        }
        let tree = [el(101, y: 0), el(102, y: 200)]
        let bridge = SemanticsOrderResponse(dump: "SemanticsNode#0\n ├─SemanticsNode#7\n └─SemanticsNode#8\n",
                                            nodes: [.init(ref: 1, semanticsId: 7, cx: 50, cy: 50),
                                                    .init(ref: 2, semanticsId: 8, cx: 50, cy: 250)], reason: nil)
        XCTAssertNil(PaintRankAnswer.make(response: bridge, elements: tree), "前提: 写さなければ使えない")
        let answer = PaintRankAnswer.make(response: MCPServer.inSessionRefs(bridge, base: 100), elements: tree)
        XCTAssertEqual(answer?.inFront(tree[1], of: tree[0]), true)
        XCTAssertNil(PaintRankAnswer.make(response: MCPServer.inSessionRefs(bridge, base: 99), elements: tree), "世代が違えば捨てる")
        let reasonOnly = SemanticsOrderResponse(dump: nil, nodes: nil, reason: "no-vm-service")
        XCTAssertEqual(MCPServer.inSessionRefs(reasonOnly, base: 100), reasonOnly)
    }

    /// VM サービスが無いと答えたアプリへは、木が変わっても聞き直さない(DSL の `semanticsOrderUnavailableApp` と同じ)。ft_launch で捨てる
    func testMissingVMServiceIsRememberedPerSession() async {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() }, recordSnapshot: { _, _, _ in })
        server.androidUIFrameworkLookup = { _, _ in .flutter }
        let args: [String: Any] = ["platform": "android", "serial": "emulator-5554"]
        let key = MCPServer.sessionKey(args)
        server.bridges[key] = "android"
        let driver = FakeDriver()
        driver.semanticsOrderAnswer = SemanticsOrderResponse(dump: nil, nodes: nil, reason: "no-vm-service")
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        func tree(rowY: Double) -> (SnapshotResponse, ElementInfo) {
            let target = ElementInfo(ref: 1, type: "button", identifier: "fab", label: "追加", value: nil, placeholder: nil,
                                     enabled: true, frame: FTRect(x: 0, y: 300, width: 400, height: 60), depth: 1)
            let row = ElementInfo(ref: 2, type: "button", identifier: "row", label: "行", value: nil, placeholder: nil,
                                  enabled: true, frame: FTRect(x: 0, y: rowY, width: 400, height: 60), depth: 1)
            return (SnapshotResponse(sessionBundleID: "com.example.release", screen: screen, elements: [target, row],
                                     truncatedCount: 0), target)
        }
        let (first, target) = tree(rowY: 320)
        _ = await server.refOccluderNaming(first, driver: driver, args: args, askingFor: target)
        let (second, _) = tree(rowY: 310)
        _ = await server.refOccluderNaming(second, driver: driver, args: args, askingFor: target)
        XCTAssertEqual(driver.semanticsOrderCalls, 1, "同じアプリには聞き直さない(聞くたびにブリッジが pidof と logcat を読む)")
        server.semanticsOrderUnavailableApps[key] = nil
        _ = await server.refOccluderNaming(second, driver: driver, args: args, askingFor: target)
        XCTAssertEqual(driver.semanticsOrderCalls, 2, "控えを捨てたら聞く")
    }
}
