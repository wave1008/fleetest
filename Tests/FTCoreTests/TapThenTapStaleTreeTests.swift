// 操作の直後のロケータ操作は、操作より前の古い木で対象を判定しない。
// E2EY-CMP(Android)の読み込みの状態: `tap(#btn_reload)` の直後の `tap(#row_l_03)` が、素取得の古い木(押せる行)で
// 「操作可能」と判定して撃ち、実際は押せない骨組みの行だった(ok のまま何も起きない)。
// 間に exist / enabledIsFalse を挟むと緑 = それらの読みが迂回して新しい木を見ていた。

import XCTest
@testable import FTCore

final class TapThenTapStaleTreeTests: XCTestCase {

    /// reload を叩くと「迂回した読み」だけが骨組み(enabled=false)を返し、素取得は叩く前の木を返し続ける。
    /// 迂回した読みは 3 回目から押せる行に戻る(読み込みの完了)
    private final class SkeletonAfterReloadDriver: AppDriver {
        private(set) var reads: [Bool] = []
        private(set) var tappedRefs: [Int] = []
        private var reloaded = false
        private var freshReadsAfterReload = 0
        var supportsCacheBypass: Bool { true }

        private func tree(rowEnabled: Bool) -> [ElementInfo] {
            [ElementInfo(ref: 1, type: "button", identifier: "btn_reload", label: nil, value: nil, placeholder: nil,
                         enabled: true, frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 0),
             ElementInfo(ref: 2, type: "button", identifier: "row_l_03", label: nil, value: nil, placeholder: nil,
                         enabled: rowEnabled, frame: FTRect(x: 0, y: 100, width: 300, height: 60), depth: 0)]
        }
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws -> String? { nil }
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { true }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse { try await snapshot(bypassingCache: false) }
        func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse {
            reads.append(bypassingCache)
            var rowEnabled = true
            if reloaded, bypassingCache {
                freshReadsAfterReload += 1
                rowEnabled = freshReadsAfterReload >= 3
            }
            return SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                    elements: tree(rowEnabled: rowEnabled), truncatedCount: 0)
        }
        func tap(ref: Int) async throws {
            tappedRefs.append(ref)
            if ref == 1 { reloaded = true }
        }
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    func testTapRightAfterTapWaitsForTheSkeletonRowToBecomeEnabled() async {
        let driver = SkeletonAfterReloadDriver()
        let executor = StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables(), uiFramework: .compose)
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn_reload")))
        let outcome = await executor.execute(
            FlowStep(action: "tap", locator: FlowLocator(id: "row_l_03"), timeout: 5))
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(outcome.notes.contains(.waitedForEnabled),
                      "古い木で押せると読んで撃った(骨組みの間に撃っている): \(driver.reads) \(outcome.notes)")
        XCTAssertEqual(driver.tappedRefs, [1, 2])
    }

    /// 兄弟の経路: 長押し(tap の holdSeconds)・doubleTap・type・clearInput の直前の解決も同じ入口(executeAction)を通る。
    /// 分類が画面を変える操作を落とさないこと
    func testEveryScreenChangingActionArmsTheNextResolveBypass() {
        let armed = StepAction.allCases.filter(\.mayChangeScreen).map(\.rawValue)
        for action in ["tap", "doubleTap", "type", "clearInput", "holdStart", "pressEnter", "hideKeyboard",
                       "pinchOut", "swipeBy", "gesture"] {
            XCTAssertTrue(armed.contains(action), action)
        }
        for action in ["select", "waitForSettle", "existImage"] {
            XCTAssertFalse(armed.contains(action), action)
        }
    }
}
