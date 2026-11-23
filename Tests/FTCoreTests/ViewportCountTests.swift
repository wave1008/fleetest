// countIs の件数が画面の大きさ・向きで変わる形(中身が枠の外へ続くスクロール容器の中を数えた)の注記(DR-204)。判定は変えない
import XCTest
@testable import FTCore

final class ViewportCountTests: XCTestCase {

    private func e(_ ref: Int, _ type: String, label: String? = nil, _ x: Double, _ y: Double, _ w: Double, _ h: Double,
                   scrollable: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: nil, label: label, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: 1, scrollable: scrollable)
    }

    /// 横向きの画面: 一覧の窓に「項目」が 2 行見え、3 行目が下の縁で半分切れている
    private var cutList: [ElementInfo] {
        [e(1, "scrollView", 0, 100, 800, 200, scrollable: true),
         e(2, "staticText", label: "項目", 0, 110, 800, 80),
         e(3, "staticText", label: "項目", 0, 200, 800, 80),
         e(4, "staticText", label: "項目", 0, 290, 800, 80)]
    }

    /// 一覧の中身が全部窓に収まっている(どの画面でも同じ数)
    private var fittingList: [ElementInfo] {
        [e(1, "scrollView", 0, 100, 400, 600, scrollable: true),
         e(2, "staticText", label: "項目", 0, 110, 400, 80),
         e(3, "staticText", label: "項目", 0, 200, 400, 80)]
    }

    func testMatchesInAListThatContinuesPastItsEdgeDependOnTheViewport() {
        let list = cutList
        XCTAssertTrue(ViewportCount.dependsOnViewport(matches: Array(list[1...2]), in: list))
    }

    /// Android は切れた行を見えている部分だけの枠で申告する(縁を跨がない)。一覧自身の「いま動かせる向き」の申告が
    /// 空でなければ続きがある(Pixel 4a の RN の FlatList で注記が付かなかった)。空の申告(動けない)・申告なし(iOS)は幾何のまま
    func testAndroidListThatDeclaresItCanScrollDependsOnTheViewport() {
        var clipped = [e(1, "scrollView", 44, 676, 992, 1159, scrollable: true),
                       e(2, "button", label: "行", 44, 676, 992, 154),
                       e(3, "button", label: "行", 44, 1793, 992, 42)]   // 下の縁で切られ、縁で終わる枠
        XCTAssertFalse(ViewportCount.dependsOnViewport(matches: Array(clipped[1...2]), in: clipped), "幾何だけでは続きが見えない")
        clipped[0].scrollActions = ["forward", "down"]
        XCTAssertTrue(ViewportCount.dependsOnViewport(matches: Array(clipped[1...2]), in: clipped))
        clipped[0].scrollActions = []
        XCTAssertFalse(ViewportCount.dependsOnViewport(matches: Array(clipped[1...2]), in: clipped), "動けない一覧は全部見えている")
    }

    func testMatchesInAListThatFitsDoNotDependOnTheViewport() {
        let list = fittingList
        XCTAssertFalse(ViewportCount.dependsOnViewport(matches: Array(list[1...2]), in: list))
    }

    func testMatchesOutsideAnyScrollerDoNotDependOnTheViewport() {
        let list = cutList
        let header = e(9, "staticText", label: "項目", 0, 20, 800, 40)
        XCTAssertFalse(ViewportCount.dependsOnViewport(matches: [header], in: list + [header]))
    }

    /// 横の帯(カルーセル)が右の縁で切れているのも同じ
    func testHorizontalCarouselCutAtTheRightEdge() {
        let row = [e(1, "scrollView", 0, 100, 400, 120, scrollable: true),
                   e(2, "button", label: "タグ", 10, 110, 150, 100),
                   e(3, "button", label: "タグ", 170, 110, 150, 100),
                   e(4, "button", label: "タグ", 330, 110, 150, 100)]
        XCTAssertTrue(ViewportCount.dependsOnViewport(matches: Array(row[1...2]), in: row))
    }

    /// countIs を通して注記が立つ(合否は変えない)
    func testCountIsCarriesTheNoteAndStillPasses() async {
        let outcome = await StepExecutor(driver: FakeAppDriver(name: "d", log: CallLog(), snapshotElements: [cutList]), isAndroid: false, tunables: RunTunables())
            .execute(FlowStep(assert: "count", locator: FlowLocator(label: "項目"), timeout: 0, expectedCount: 3))
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(outcome.notes.contains(.countInScrollingList), "\(outcome.notes)")
    }

    func testCountIsInAFittingListHasNoNote() async {
        let outcome = await StepExecutor(driver: FakeAppDriver(name: "d", log: CallLog(), snapshotElements: [fittingList]), isAndroid: false, tunables: RunTunables())
            .execute(FlowStep(assert: "count", locator: FlowLocator(label: "項目"), timeout: 0, expectedCount: 2))
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertFalse(outcome.notes.contains(.countInScrollingList), "\(outcome.notes)")
    }
}
