// 手前の窓・モーダルに覆われた要素: 探索(scroll:)の失敗文と検証(exist・textEquals)の見つからない失敗文が、
// 木の覆いの申告を名指し、waitSeconds: / 逆向きの案内を出さない。申告の無い木は従来どおり。

import XCTest
@testable import FTCore

final class CoverReportInFailureMessagesTests: XCTestCase {
    private final class CoveredDriver: AppDriver {
        let front: FrontWindowCover?
        let modal: ModalScopeCover?
        init(front: FrontWindowCover? = nil, modal: ModalScopeCover? = nil) { self.front = front; self.modal = modal }

        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws -> String? { nil }
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                             elements: [ElementInfo(ref: 1, type: "button", identifier: "other", label: nil, value: nil,
                                                    placeholder: nil, enabled: true,
                                                    frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 1)],
                             truncatedCount: 0, coveredByFrontWindow: front, modalScope: modal)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private let front = FrontWindowCover(droppedCount: 15, frames: [FTRect(x: 0, y: 0, width: 402, height: 874)])
    private let modal = ModalScopeCover(droppedCount: 3, frames: [FTRect(x: 20, y: 300, width: 362, height: 200)])

    private func reason(_ step: FlowStep, _ driver: CoveredDriver) async -> String {
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables()).execute(step)
        if case .failed(let r) = outcome.status { return r }
        XCTFail("failed を期待: \(outcome.status)")
        return ""
    }

    private func searchStep(_ action: String) -> FlowStep {
        FlowStep(action: action, locator: FlowLocator(id: "gone"), direction: "down", maxSwipes: 2)
    }

    func testScrollSearchNamesFrontWindowAndDropsWaitAndOppositeAdvice() async {
        let m = await reason(searchStep("scrollTo"), CoveredDriver(front: front))
        XCTAssertTrue(m.contains("a window in front of the app"), m)
        XCTAssertTrue(m.contains("waiting will not bring"), m)
        XCTAssertFalse(m.contains("waitSeconds:"), m)
        XCTAssertFalse(m.contains("scroll: .up"), m)
        XCTAssertFalse(m.contains("opposite direction"), m)
    }

    func testScrollSearchNamesModalScope() async {
        let m = await reason(searchStep("scrollTo"), CoveredDriver(modal: modal))
        XCTAssertTrue(m.contains("a modal view (accessibilityViewIsModal)"), m)
        XCTAssertFalse(m.contains("waitSeconds:"), m)
    }

    func testScrollSearchWithoutReportKeepsTheOldAdvice() async {
        let m = await reason(searchStep("scrollTo"), CoveredDriver())
        XCTAssertFalse(m.contains("a window in front"), m)
        XCTAssertFalse(m.contains("modal view"), m)
        XCTAssertTrue(m.contains("opposite direction was not searched"), m)
    }

    func testExistNamesTheCoverAndWithoutReportStaysPlain() async {
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "gone"), timeout: 0)
        let covered = await reason(step, CoveredDriver(front: front))
        XCTAssertTrue(covered.contains("element not found: id=gone"), covered)
        XCTAssertTrue(covered.contains("a window in front of the app"), covered)
        let modalMsg = await reason(step, CoveredDriver(modal: modal))
        XCTAssertTrue(modalMsg.contains("a modal view (accessibilityViewIsModal)"), modalMsg)
        let plain = await reason(step, CoveredDriver())
        XCTAssertFalse(plain.contains("a window in front"), plain)
        XCTAssertFalse(plain.contains("modal view"), plain)
    }

    func testTextEqualsNamesTheCover() async {
        let step = FlowStep(assert: "textEquals", locator: FlowLocator(id: "gone"), expected: "x", timeout: 0)
        let covered = await reason(step, CoveredDriver(front: front))
        XCTAssertTrue(covered.contains("element not found"), covered)
        XCTAssertTrue(covered.contains("a window in front of the app"), covered)
        let plain = await reason(step, CoveredDriver())
        XCTAssertFalse(plain.contains("a window in front"), plain)
    }
}
