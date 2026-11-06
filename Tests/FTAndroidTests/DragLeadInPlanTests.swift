// OI-168 ⑥: 短くて遅い寄せのドラッグが slop を長押しのしきい値より十分前に越える。

import XCTest
@testable import FTEmulatorGrpc

final class DragLeadInPlanTests: XCTestCase {
    private typealias S = EmulatorGrpcSession

    /// 観測した形(CMP の Android 横向き・Emulator 420dpi = 2.625 px/dp・寄せ 31px を 0.6 秒)
    func testObservedNudgeGetsALeadInThatCrossesSlopWellBeforeLongPress() throws {
        let plan = try XCTUnwrap(S.leadInPlan(distancePx: 31, durationMs: 600, densityPxPerDp: 2.625))
        let slop = S.touchSlopDp * 2.625
        XCTAssertGreaterThan(plan.px, slop)
        let t = Double(plan.ms) * slop / plan.px   // 最初の区間の中で slop を越える時刻
        XCTAssertLessThan(t, Double(S.longPressTimeoutMs) / 2)
        XCTAssertEqual(plan.ms, 150)
    }

    func testProgressKeepsTotalDistanceAndDurationAndEndsAtTheTarget() throws {
        let plan = try XCTUnwrap(S.leadInPlan(distancePx: 31, durationMs: 600, densityPxPerDp: 2.625))
        func p(_ t: Double) -> Double { S.dragProgress(atMs: t, durationMs: 600, distancePx: 31, leadIn: plan) }
        XCTAssertEqual(p(0), 0, accuracy: 1e-9)
        XCTAssertEqual(p(Double(plan.ms)) * 31, plan.px, accuracy: 1e-6)
        XCTAssertEqual(p(600), 1, accuracy: 1e-9)
        XCTAssertGreaterThan(p(300), p(150))   // 単調
        XCTAssertGreaterThan(p(150) * 31, S.touchSlopDp * 2.625)
    }

    func testNoPlanKeepsLinearProgress() {
        XCTAssertEqual(S.dragProgress(atMs: 150, durationMs: 600, distancePx: 31, leadIn: nil), 0.25, accuracy: 1e-9)
    }

    /// 普通の寄せ・探索のドラッグ(120px/s)は slop を 200ms 前に越えるので触らない(慣性を残さない遅さを変えない)
    func testOrdinarySlowDragsAreLeftAlone() {
        XCTAssertNil(S.leadInPlan(distancePx: 189, durationMs: 1575, densityPxPerDp: 2.625))
        XCTAssertNil(S.leadInPlan(distancePx: 200, durationMs: 600, densityPxPerDp: 2.625))
        XCTAssertNil(S.leadInPlan(distancePx: 31, durationMs: 150, densityPxPerDp: 2.625), "最初の区間より短い")
    }

    /// slop を越えない距離はドラッグにならない = 触らない(越える動きに作り替えない)
    func testDistanceBelowSlopIsLeftAlone() {
        XCTAssertNil(S.leadInPlan(distancePx: 15, durationMs: 600, densityPxPerDp: 2.625))
        XCTAssertNil(S.leadInPlan(distancePx: 31, durationMs: 600, densityPxPerDp: 0))
    }

    func testDriverPassesThePlanToTheGrpcDrag() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/FTAndroid/AndroidDriver.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("leadIn: EmulatorGrpcSession.leadInPlan("))
    }
}
