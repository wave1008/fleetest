// iOS: 容器の下端で見切れた要素は、撃つ前に全体が見えるまで上へ送る(中心が描かれていない所に落ちて焦点が立たない)。
// 木は E2EX-CMP「入力の種類」の実物の枠(`#field_bottom` だけ高さ 46・他の欄は 64)

import XCTest
@testable import FTCore

final class BottomEdgeClipLiftTests: XCTestCase {

    private func field(_ ref: Int, _ id: String, y: Double, h: Double = 64) -> ElementInfo {
        ElementInfo(ref: ref, type: "textView", identifier: id, label: nil, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 16, y: y, width: 370, height: h), depth: 2)
    }

    private var tree: [ElementInfo] {
        [ElementInfo(ref: 1, type: "scrollView", identifier: nil, label: nil, value: nil, placeholder: nil,
                     enabled: true, frame: FTRect(x: 0, y: 0, width: 402, height: 874), depth: 1, scrollable: true),
         field(2, "field_number", y: 322), field(3, "field_password", y: 398), field(4, "field_first", y: 598),
         field(5, "field_second", y: 675), field(6, "field_auto", y: 751), field(7, "field_bottom", y: 827, h: 46)]
    }

    func testFieldCutOffAtTheBottomEdgeIsLifted() throws {
        let bottom = tree.first { $0.identifier == "field_bottom" }!
        let jump = try XCTUnwrap(TapTargetGeometry.bottomEdgeClipLift(bottom, in: tree))
        XCTAssertGreaterThanOrEqual(jump, 64 - 46, "欠けた高さ以上は送る")
    }

    func testFullyDrawnFieldIsNotLifted() {
        let auto = tree.first { $0.identifier == "field_auto" }!
        XCTAssertNil(TapTargetGeometry.bottomEdgeClipLift(auto, in: tree))
    }
}

/// Android: 見切れた行は見えている部分を押せるので送らない。ただし見えている部分が文字を描けない細さ(DR-231 の床 =
/// `minimumVisibleTapExtent` × pointScale)なら送る(探索が対象を縁の細い帯で止めると、続く exist が「無い」と読む)
final class AndroidSliverEdgeLiftTests: XCTestCase {
    private func row(_ ref: Int, _ id: String, y: Double, h: Double = 168) -> ElementInfo {
        ElementInfo(ref: ref, type: "button", identifier: id, label: id, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 48, y: y, width: 1184, height: h), depth: 2)
    }

    private func tree(lastRowHeight: Double) -> [ElementInfo] {
        [ElementInfo(ref: 1, type: "scrollView", identifier: "list_rows", label: nil, value: nil, placeholder: nil,
                     enabled: true, frame: FTRect(x: 48, y: 745, width: 1184, height: 1561), depth: 1, scrollable: true),
         row(2, "row_19", y: 1930), row(3, "row_20", y: 2104),
         row(4, "row_21", y: 2306 - lastRowHeight, h: lastRowHeight)]
    }

    private func run(lastRowHeight: Double) async -> FakeAppDriver {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [tree(lastRowHeight: lastRowHeight)])
        _ = await StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables(defaultTimeout: 0.2))
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "row_21")))
        return driver
    }

    /// 床は `minimumVisibleTapExtent`(8)× 偽ドライバの pointScale(1)
    func testSliverAtTheBottomEdgeIsLiftedOnAndroid() async {
        let driver = await run(lastRowHeight: TapTargetGeometry.minimumVisibleTapExtent / 2)
        XCTAssertFalse(driver.dragCalls.isEmpty, "床より細い帯で止まった行を送らなかった")
    }

    func testPartlyVisibleRowIsNotLiftedOnAndroid() async {
        let driver = await run(lastRowHeight: TapTargetGeometry.minimumVisibleTapExtent * 4)
        XCTAssertTrue(driver.dragCalls.isEmpty, "見えている部分を押せる行まで送った: \(driver.dragCalls)")
    }
}
