// シート展開救済の打ち切り判定(`MCPServer.visibleAfterExpansion`)。
//
// 2026-08-12 の実アプリ監査(Apple マップの乗換案内・iOS 27 Simulator)で踏んだ形:
// 救済がシートを広げて目標を画面に出した**直後に、同じ探索をもう一度スワイプで走らせる**。
// この画面ではリスト内のスワイプが外側シートの折りたたみに化けるため、出した行を自分で
// 引っ込めて「見つからない」で終わっていた。実測 20.4 秒かけて失敗 → 打ち切り後は 5.3 秒で成功
// (救済の内訳は +16.9s → +1.6s)。手で展開してから同じ探索を撃つと 0 スワイプ・512ms で通る、
// という対照実験がこの判定の根拠。

import XCTest
import FTCore
@testable import fleetest_mcp

final class SheetExpansionRevealTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    private func element(_ ref: Int, _ id: String, _ label: String?, _ type: String,
                         _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: 2)
    }

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements,
                         truncatedCount: 0)
    }

    private func step(_ selector: String) -> FlowStep {
        FlowStep(action: "scrollTo", locator: FTSelector.parse(selector).primary)
    }

    /// 展開後の木に目標が画面内で載っていたら、そこで打ち切る
    func testRevealedTargetStopsTheRescue() {
        let snap = snapshot([
            element(88, "TitleLabel", "立川駅", "staticText", 20, 92, 84, 36),
            element(90, "TransitDirectionsListView", nil, "scrollView", 0, 144, 402, 730),
        ])
        let hit = MCPServer.visibleAfterExpansion(step: step("*立川*"), in: snap)
        XCTAssertEqual(hit?.ref, 88)
    }

    /// 載っていなければ従来どおり再試行へ進む(救済を奪わない)
    func testAbsentTargetKeepsTheRetry() {
        let snap = snapshot([
            element(90, "TransitDirectionsListView", nil, "scrollView", 0, 144, 402, 730),
            element(91, "PrimaryLabel", "新宿で降車", "staticText", 64, 328, 276, 26),
        ])
        XCTAssertNil(MCPServer.visibleAfterExpansion(step: step("*立川*"), in: snap))
    }

    /// **画面の外に居るだけの一致で打ち切らない** —— 展開しても紙の下に隠れたままの行は
    /// 「出た」ではない。ここを緩めると、探索が要る場面で救済ごと失われる
    func testOffscreenMatchDoesNotCount() {
        let snap = snapshot([
            element(88, "PrimaryLabel", "立川で降車", "staticText", 64, 1200, 276, 26),
        ])
        XCTAssertNil(MCPServer.visibleAfterExpansion(step: step("*立川*"), in: snap))
    }

    /// 退化 frame(幅・高さ 0)も「出た」とは言わない
    func testZeroSizedMatchDoesNotCount() {
        let snap = snapshot([
            element(88, "PrimaryLabel", "立川で降車", "staticText", 64, 300, 0, 0),
        ])
        XCTAssertNil(MCPServer.visibleAfterExpansion(step: step("*立川*"), in: snap))
    }

    /// セレクタを持たないステップでは黙る(scrollTo 以外が紛れ込んでも誤って成功にしない)
    func testStepWithoutALocatorIsSilent() {
        let snap = snapshot([element(88, "TitleLabel", "立川駅", "staticText", 20, 92, 84, 36)])
        XCTAssertNil(MCPServer.visibleAfterExpansion(step: FlowStep(action: "scrollTo"), in: snap))
    }

    /// 容器の中に一致が無ければ、外の一致もそのまま返す(呼び手が `matchIsOutsideScrollFrame` で失敗に倒す)。
    /// 実際の例 —— 見出し `立川駅` はリスト容器の外に居る
    func testMatchOutsideTheScrollContainerStillCounts() {
        let header = element(88, "TitleLabel", "立川駅", "staticText", 20, 92, 84, 36)
        let snap = snapshot([header,
                             element(90, "TransitDirectionsListView", nil, "scrollView",
                                     0, 144, 402, 730)])
        var scrollStep = step("*立川*")
        scrollStep.scrollFrameRect = FTRect(x: 0, y: 144, width: 402, height: 730)
        XCTAssertEqual(MCPServer.visibleAfterExpansion(step: scrollStep, in: snap)?.ref, header.ref)
    }

    /// scrollFrame を渡されていて一致が容器の外 → 外と判定(呼び手はこれを成功にしない)。中・容器なしは false
    func testOutsideMatchIsDetectedOnlyWhenAContainerIsKnown() {
        let header = element(88, "TitleLabel", "立川駅", "staticText", 20, 92, 84, 36)
        let row = element(91, "Row", "立川駅 5:48", "cell", 0, 200, 402, 44)
        let snap = snapshot([header, row])
        var withFrame = step("*立川*")
        withFrame.scrollFrameRect = FTRect(x: 0, y: 144, width: 402, height: 730)
        XCTAssertTrue(MCPServer.matchIsOutsideScrollFrame(header, step: withFrame, in: snap))
        XCTAssertFalse(MCPServer.matchIsOutsideScrollFrame(row, step: withFrame, in: snap))
        XCTAssertFalse(MCPServer.matchIsOutsideScrollFrame(header, step: step("*立川*"), in: snap),
                       "scrollFrame を渡されていなければ従来どおり成功")
        // 容器の下端で数 pt はみ出した行は中(リストの行に届いている)
        let edgeRow = element(92, "Row", "立川駅 6:02", "cell", 0, 850, 402, 44)
        XCTAssertFalse(MCPServer.matchIsOutsideScrollFrame(edgeRow, step: withFrame, in: snapshot([header, edgeRow])),
                       "端で一部がはみ出しただけの行を外と読まない")
    }

    /// ft_scroll_to の救済の分岐が、外の一致を .passed にしない(判定を外す変異で落ちる)
    func testRescueBranchDoesNotPassAnOutsideMatch() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/fleetest-mcp/MCPServer+Snapshot.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let guardRange = try XCTUnwrap(text.range(of: "if Self.matchIsOutsideScrollFrame(alreadyThere"))
        let rest = text[guardRange.upperBound...]
        let elseRange = try XCTUnwrap(rest.range(of: "} else {"))
        let outsideBranch = rest[..<elseRange.lowerBound]
        XCTAssertFalse(outsideBranch.contains(".passed"), "outside match must stay a miss")
        XCTAssertTrue(outsideBranch.contains("matchOutsideContainer = true"))
    }
}
