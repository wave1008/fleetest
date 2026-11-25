import XCTest
@testable import FTCore

/// 一覧の縁で切れた一致候補は `revealClippedAppIcon` がドラッグ1本で見える位置へ戻す。切れていなければ撃たない
final class OI391AppIconRevealTests: XCTestCase {

    private func el(_ ref: Int, _ label: String, _ frame: FTRect, scrollable: Bool? = nil, type: String = "staticText",
                    id: String = "icon", depth: Int = 1) -> ElementInfo {
        var e = ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil, placeholder: nil,
                            enabled: true, frame: frame, depth: depth)
        e.scrollable = scrollable
        return e
    }

    private func snapshot(firstRow: FTRect) -> SnapshotResponse {
        var list = el(1, "", FTRect(x: 0, y: 195, width: 1080, height: 2025), scrollable: true,
                      type: "collectionView", id: "apps_list_view", depth: 0)
        list.label = nil
        return SnapshotResponse(
            sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 1080, height: 2220),
            elements: [list, el(2, "Firefox", firstRow),
                       el(3, "Other1", FTRect(x: 439, y: 700, width: 201, height: 316)),
                       el(4, "Other2", FTRect(x: 439, y: 1100, width: 201, height: 316))],
            truncatedCount: 0)
    }

    private func executor() -> (StepExecutor, FakeAppDriver) {
        let driver = FakeAppDriver(name: "p", log: CallLog())
        return (StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables()), driver)
    }

    func testClippedIconIsDraggedBackIntoView() async {
        let (executor, driver) = executor()
        let revealed = await executor.revealClippedAppIcon(
            named: "Firefox", in: snapshot(firstRow: FTRect(x: 439, y: 195, width: 201, height: 88)))
        XCTAssertTrue(revealed)
        XCTAssertEqual(driver.dragCalls.count, 1, "\(driver.dragCalls)")
    }

    func testUnclippedIconIsNotDragged() async {
        let (executor, driver) = executor()
        let revealed = await executor.revealClippedAppIcon(
            named: "Firefox", in: snapshot(firstRow: FTRect(x: 439, y: 300, width: 201, height: 316)))
        XCTAssertFalse(revealed)
        XCTAssertTrue(driver.dragCalls.isEmpty, "\(driver.dragCalls)")
    }
}
