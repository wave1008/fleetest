// 対象外の回し直し(DR-214)の配線の走査。RunOrchestrator の分岐はデバイス無しでは通らない(緑の run で1度も実行されない形)ので、
// 判定の1箇所化と「確定させない」順序を走査で固定する。判定そのものは NotApplicableHandoffTests / ScenarioQueueNotApplicableTests /
// DynamicDispatcherNotApplicableTests が持つ。

import XCTest

final class NotApplicableHandoffWiringTests: XCTestCase {

    private static func code(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// 判定の規則を持つのは `NotApplicableHandoff.decide` の1箇所。機械の中と親が同じ関数を呼ぶ
    func testBothSidesCallTheSharedDecision() throws {
        let queue = try Self.code("Sources/FTCore/ScenarioQueue.swift")
        let dispatcher = try Self.code("Sources/fleetest/DynamicDispatcher.swift")
        XCTAssertEqual(queue.components(separatedBy: "NotApplicableHandoff.decide(").count - 1, 1)
        XCTAssertEqual(dispatcher.components(separatedBy: "NotApplicableHandoff.decide(").count - 1, 1)
    }

    /// 対象外の終了イベントは保留し、行き先を決めてから(回し直す・赤にするなら捨て理由つきの失敗として)流す。
    /// 記録は捨ててから行き先を適用する(二重に数えない)
    func testOrchestratorHoldsTheFinishAndAppliesTheVerdictBeforeCounting() throws {
        let text = try Self.code("Sources/FTCore/RunOrchestrator.swift")
        XCTAssertTrue(text.contains("if holdsFinish || declaredNotApplicable != nil {"), "対象外の終了イベントを保留していない")
        let resolve = try XCTUnwrap(text.range(of: "await resolveNotApplicable(item, worker: worker, queue: queue, declared: declared)"))
        let release = try XCTUnwrap(text.range(of: "Self.failedFinish(held.event, discardReason: discardReason)"))
        XCTAssertLessThan(resolve.lowerBound, release.lowerBound, "終了イベントを流す前に行き先を決める")
        XCTAssertTrue(text.contains("if outcome == .notApplicable, notApplicableFollowUp == nil { await runSkipped.increment() }"),
                      "回し直す・赤にする対象外を skipped に数えない")
        XCTAssertTrue(text.contains("recorder?.discardLast(unit: item.unitKey, worker: ScenarioRunner.recordingWorker(worker))"),
                      "確定させない対象外の記録を捨てていない")
        // デバイスに束ねたクラス・@RunOnSingleMachine は機械の外へ出さない
        XCTAssertTrue(text.contains("item.info.placement == nil"))
    }

    /// 親へ聞く経路(`ScenarioPullSource.declareNotApplicable`)は既定実装を持たない(新しい配り手が忘れるとコンパイルで止まる)
    func testPullSourceHasNoDefaultNotApplicableImplementation() throws {
        let plan = try Self.code("Sources/FTCore/BroadcastPlan.swift")
        XCTAssertTrue(plan.contains("func declareNotApplicable("))
        let extensions = plan.components(separatedBy: "extension ScenarioPullSource")
        XCTAssertEqual(extensions.count, 1, "ScenarioPullSource に既定実装の extension を足さない")
    }
}
