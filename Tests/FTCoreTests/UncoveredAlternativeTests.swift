// 同じセレクタに一致した候補のうち、先頭が手前の要素に覆われていれば、覆われていない候補を撃つ
// (E2EY-RN の A4 スワイプの操作: 全行の「アーカイブ」が行の裏に常にあり、行4を開いて露出したのに、
// 先頭 = 行1の裏のボタンを撃って行1を開いた。iOS 5/5・Android 2/2)

import XCTest
@testable import FTCore

final class UncoveredAlternativeTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    private func element(_ ref: Int, _ type: String, _ id: String, _ label: String?, _ frame: FTRect, depth: Int) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil, placeholder: nil,
                    enabled: true, frame: frame, depth: depth)
    }

    /// 行 1〜4(y=100 から 80 刻み)。各行の裏に「アーカイブ」(右端)を先に並べ、行を後に並べる = 行が手前。
    /// `openRows` の行だけ左へ 120 ずれてボタンが露出する
    private func swipeList(openRows: Set<Int>) -> [ElementInfo] {
        var elements = [element(1, "other", "list", nil, FTRect(x: 0, y: 80, width: 402, height: 400), depth: 1)]
        for row in 1...4 {
            let y = 100.0 + Double(row - 1) * 80
            elements.append(element(10 + row, "button", "btn_sw_archive_\(row)", "アーカイブ",
                                    FTRect(x: 282, y: y, width: 120, height: 70), depth: 2))
        }
        for row in 1...4 {
            let y = 100.0 + Double(row - 1) * 80
            let x = openRows.contains(row) ? -120.0 : 0
            elements.append(element(20 + row, "clickable", "sw_row_\(row)", "行 \(row)",
                                    FTRect(x: x, y: y, width: 402, height: 70), depth: 2))
        }
        return elements
    }

    func testExposedMatchIsPickedOverTheCoveredFirstMatch() throws {
        let tree = swipeList(openRows: [4])
        let candidates = tree.filter { $0.label == "アーカイブ" }
        let picked = try XCTUnwrap(OcclusionGeometry.uncoveredAlternative(
            to: candidates[0], among: candidates, in: tree, screen: screen))
        XCTAssertEqual(picked.identifier, "btn_sw_archive_4")
    }

    /// 全部覆われている(どの行も開いていない)なら替えない
    func testAllCoveredKeepsTheFirstMatch() {
        let tree = swipeList(openRows: [])
        let candidates = tree.filter { $0.label == "アーカイブ" }
        XCTAssertNil(OcclusionGeometry.uncoveredAlternative(to: candidates[0], among: candidates, in: tree, screen: screen))
    }

    /// 先頭が覆われていなければ替えない(木の順の先頭を撃つ従来どおり。行4も開いていて替える先はある)
    func testUncoveredFirstMatchIsKept() {
        let tree = swipeList(openRows: [1, 4])
        let candidates = tree.filter { $0.label == "アーカイブ" }
        XCTAssertNil(OcclusionGeometry.uncoveredAlternative(to: candidates[0], among: candidates, in: tree, screen: screen))
    }

    /// 全部覆われている(どの行も開いていない)なら撃たずに失敗にする(配線。塗り順のある木 = `PaintOrder.isReal`)
    func testTapRefusesWhenEveryMatchIsCovered() async throws {
        let driver = FixedTreeDriver(elements: swipeList(openRows: []), screen: screen)
        let outcome = await StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables(), uiFramework: .androidView)
            .execute(FlowStep(action: "tap", locator: FlowLocator(label: "アーカイブ")))
        XCTAssertTrue(driver.tappedRefs.isEmpty, "覆われたボタンを撃った: \(driver.tappedRefs)")
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(message.contains("every one is covered"), message)
    }

    /// 1件しか実体が無ければ従来どおり撃つ(覆いの判定の誤検知を失敗にしない)
    func testSingleCoveredMatchStillFires() {
        let tree = swipeList(openRows: [])
        let candidates = tree.filter { $0.identifier == "btn_sw_archive_1" }
        XCTAssertNil(OcclusionGeometry.coveringWhenEveryMatchIsCovered(
            chosen: candidates[0], among: candidates, in: tree, screen: screen))
    }

    /// DSL の tap が覆われていない候補を撃つ(配線。塗り順のある木 = `PaintOrder.isReal`)
    func testTapTouchesTheExposedMatch() async throws {
        let driver = FixedTreeDriver(elements: swipeList(openRows: [4]), screen: screen)
        let outcome = await StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables(), uiFramework: .androidView)
            .execute(FlowStep(action: "tap", locator: FlowLocator(label: "アーカイブ")))
        XCTAssertEqual(driver.tappedRefs, [14], "覆われた行1の裏のボタン(11)を撃った: \(driver.tappedRefs)")
        XCTAssertTrue(outcome.driverFallback?.contains("uncovered match #btn_sw_archive_4") ?? false,
                      outcome.driverFallback ?? "-")
    }

    /// 塗り順の無い木(フレームワーク不明の Android)では同じ形でも替えない・断らない: 先頭の候補をそのまま撃つ
    func testTapKeepsTheFirstMatchWhenPaintOrderIsUnknown() async throws {
        let exposed = FixedTreeDriver(elements: swipeList(openRows: [4]), screen: screen)
        let exposedOutcome = await StepExecutor(driver: exposed, isAndroid: true, tunables: RunTunables())
            .execute(FlowStep(action: "tap", locator: FlowLocator(label: "アーカイブ")))
        XCTAssertEqual(exposed.tappedRefs, [11], "別の候補へ替えた: \(exposed.tappedRefs)")
        XCTAssertFalse(exposedOutcome.driverFallback?.contains("uncovered match") ?? false, exposedOutcome.driverFallback ?? "-")

        let covered = FixedTreeDriver(elements: swipeList(openRows: []), screen: screen)
        let coveredOutcome = await StepExecutor(driver: covered, isAndroid: true, tunables: RunTunables())
            .execute(FlowStep(action: "tap", locator: FlowLocator(label: "アーカイブ")))
        if case .failed(let message) = coveredOutcome.status {
            XCTAssertFalse(message.contains("every one is covered"), message)
        }
        XCTAssertFalse(covered.tappedRefs.isEmpty, "全部覆われていても断らずに撃つ")
    }
}

/// 木を固定で返し、撃った ref を控えるドライバ
private final class FixedTreeDriver: AppDriver {
    let elements: [ElementInfo]
    let screen: FTRect
    private(set) var tappedRefs: [Int] = []

    init(elements: [ElementInfo], screen: FTRect) {
        self.elements = elements
        self.screen = screen
    }

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws -> String? { nil }
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func terminate() async throws {}
    func screenshot() async throws -> Data { Data() }
    func type(ref: Int?, text: String) async throws {}
    func tap(ref: Int) async throws { tappedRefs.append(ref) }
    func tap(x: Double, y: Double) async throws {
        if let hit = elements.last(where: { $0.frame.x <= x && x <= $0.frame.x + $0.frame.width
            && $0.frame.y <= y && y <= $0.frame.y + $0.frame.height }) { tappedRefs.append(hit.ref) }
    }
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements, truncatedCount: 0)
    }
}
