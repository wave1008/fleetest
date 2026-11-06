// OI-163 ⑨(向きを申告しない容器の軸を中の子の並びで決める)と ⑰(キーボードが容器の下部を覆ったまま動かない探索)。

import XCTest
@testable import FTCore

private func el(_ ref: Int, _ type: String, id: String? = nil, _ x: Double, _ y: Double, _ w: Double, _ h: Double,
                scrollable: Bool? = nil, actions: [String]? = nil) -> ElementInfo {
    ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil, placeholder: nil, enabled: true,
                frame: FTRect(x: x, y: y, width: w, height: h), depth: 1, scrollable: scrollable, scrollActions: actions)
}

private final class KeyboardDriver: AppDriver {
    private(set) var hideCount = 0
    private let closes: Bool
    private var closed = false
    init(closes: Bool) { self.closes = closes }

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
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {}
    func hideKeyboard() async throws { hideCount += 1; if closes { closed = true } }
    func snapshot() async throws -> SnapshotResponse {
        var elements = [el(1, "other", id: "form", 48, 811, 1184, 1997, scrollable: true, actions: ["up", "down"]),
                        el(2, "clickable", id: "field_number", 48, 847, 1184, 168)]
        if closed { elements.append(el(3, "clickable", id: "field_bottom", 48, 2000, 1184, 168)) }
        return SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 1280, height: 2856),
                                elements: elements, truncatedCount: 0,
                                keyboardShown: !closed,
                                keyboardFrame: closed ? nil : FTRect(x: 0, y: 1848, width: 1280, height: 1008))
    }
}

final class ScrollSearchAxisInferenceAndKeyboardTests: XCTestCase {
    /// E2E-Flutter 横向きのスクロール画面の形(軸の無い forward だけの容器 2 つ。横のカルーセルは子が横に並ぶ)
    private func flutterLandscape() -> SnapshotResponse {
        var elements = [el(1, "Other", id: "list_rows", 204, 648, 2604, 128),
                        el(2, "ScrollView", 204, 648, 2604, 128, scrollable: true, actions: ["forward"]),
                        el(3, "Button", id: "row_01", 204, 648, 2604, 128),
                        el(4, "Other", id: "carousel_tags", 204, 776, 2604, 180),
                        el(5, "ScrollView", 204, 776, 2604, 180, scrollable: true, actions: ["forward"])]
        for i in 0..<8 { elements.append(el(6 + i, "Button", id: "tag_0\(i + 1)", 204 + Double(i) * 360, 776, 360, 180)) }
        return SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 2856, height: 1280),
                                elements: elements, truncatedCount: 0)
    }

    func testAxisLessHorizontalContainerIsNotCountedForVerticalSearch() {
        let snapshot = flutterLandscape()
        let only = ContainerGeometry.uniqueScrollContainer(in: snapshot, vertical: true)
        XCTAssertEqual(only?.ref, 2)
        XCTAssertEqual(StepExecutor.directionMatchedScrollFrameCandidate(in: snapshot, vertical: true), "#list_rows")
    }

    func testUndeterminedAxisContainersStayAmbiguous() {
        var snapshot = flutterLandscape()
        // カルーセルの子を消す = 並びから軸が決まらない → 従来どおり 2 つと数えて nil
        snapshot = SnapshotResponse(sessionBundleID: nil, screen: snapshot.screen,
                                    elements: snapshot.elements.filter { !($0.identifier ?? "").hasPrefix("tag_") },
                                    truncatedCount: 0)
        XCTAssertNil(ContainerGeometry.uniqueScrollContainer(in: snapshot, vertical: true))
    }

    func testKeyboardCoverGeometry() {
        let container = FTRect(x: 48, y: 811, width: 1184, height: 1997)
        XCTAssertTrue(StepExecutor.keyboardCoversContainerBottom(FTRect(x: 0, y: 1848, width: 1280, height: 1008), container: container))
        XCTAssertFalse(StepExecutor.keyboardCoversContainerBottom(FTRect(x: 0, y: 2900, width: 1280, height: 100), container: container))
        XCTAssertFalse(StepExecutor.keyboardCoversContainerBottom(FTRect(x: 0, y: 500, width: 1280, height: 2300), container: container))
    }

    private func step() -> FlowStep {
        FlowStep(action: "scrollTo", locator: FlowLocator(id: "field_bottom"), direction: "up", timeout: 1, maxSwipes: 4)
    }

    func testClosesKeyboardOnceAndFindsTarget() async {
        let driver = KeyboardDriver(closes: true)
        let result = await StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables()).execute(step())
        XCTAssertEqual(driver.hideCount, 1)
        guard case .passed = result.status else { return XCTFail("\(result.status)") }
    }

    func testKeyboardThatStaysOpenKeepsTheOriginalFailure() async {
        let driver = KeyboardDriver(closes: false)
        let result = await StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables()).execute(step())
        XCTAssertEqual(driver.hideCount, 1, "閉じられなかった探索で撃ち直さない")
        guard case .failed(let reason) = result.status else { return XCTFail("\(result.status)") }
        XCTAssertTrue(reason.contains("nothing moved at all"), reason)
    }
}
