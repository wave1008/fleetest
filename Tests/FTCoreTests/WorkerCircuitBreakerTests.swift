@testable import FTCore
import XCTest

/// 離脱には証拠(streak の間に別レーンが通った)を要求する(WorkerCircuitBreaker の冒頭)
final class WorkerCircuitBreakerTests: XCTestCase {

    func testBelowThresholdKeeps() {
        var b = WorkerCircuitBreaker(threshold: 3)
        XCTAssertEqual(b.recordFailure(runPasses: 0), .keep)
        XCTAssertEqual(b.recordFailure(runPasses: 0), .keep)
        XCTAssertEqual(b.consecutiveFailures, 2)
    }

    /// 1レーンだけ不調(他レーンは通っている)= 従来どおり離脱
    func testTripsWhenAnotherLanePassedDuringTheStreak() {
        var b = WorkerCircuitBreaker(threshold: 3)
        XCTAssertEqual(b.recordFailure(runPasses: 5), .keep)
        XCTAssertEqual(b.recordFailure(runPasses: 6), .keep)      // 他レーンが1本通った
        XCTAssertEqual(b.recordFailure(runPasses: 6), .trip(consecutive: 3))
    }

    /// 全レーンが同時に落ちている(誰も通らない)= 離脱しない。言うのは streak で1回だけ
    func testHeldWhenNobodyPassedSinceTheStreakBegan() {
        var b = WorkerCircuitBreaker(threshold: 3)
        XCTAssertEqual(b.recordFailure(runPasses: 5), .keep)
        XCTAssertEqual(b.recordFailure(runPasses: 5), .keep)
        XCTAssertEqual(b.recordFailure(runPasses: 5), .held(consecutive: 3, announce: true))
        XCTAssertEqual(b.recordFailure(runPasses: 5), .held(consecutive: 4, announce: false))
    }

    /// 保留中に他レーンが通ったら、次の失敗で離脱する(証拠が後から揃う)
    func testHeldThenTripsOnceEvidenceArrives() {
        var b = WorkerCircuitBreaker(threshold: 3)
        _ = b.recordFailure(runPasses: 0)
        _ = b.recordFailure(runPasses: 0)
        XCTAssertEqual(b.recordFailure(runPasses: 0), .held(consecutive: 3, announce: true))
        XCTAssertEqual(b.recordFailure(runPasses: 1), .trip(consecutive: 4))
    }

    /// 自レーンの通過は streak を切り、通過数の基準も取り直す(streak 前の他レーンの通過は証拠にしない)
    func testPassResetsTheStreakAndTheBaseline() {
        var b = WorkerCircuitBreaker(threshold: 3)
        _ = b.recordFailure(runPasses: 0)
        _ = b.recordFailure(runPasses: 0)
        b.recordPass()
        XCTAssertEqual(b.consecutiveFailures, 0)
        // streak 前に他レーンが 3 本通っていても、新しい streak の間に誰も通らなければ held
        XCTAssertEqual(b.recordFailure(runPasses: 4), .keep)
        XCTAssertEqual(b.recordFailure(runPasses: 4), .keep)
        XCTAssertEqual(b.recordFailure(runPasses: 4), .held(consecutive: 3, announce: true))
        // 新しい streak では改めて1回だけ言う
        b.recordPass()
        _ = b.recordFailure(runPasses: 4); _ = b.recordFailure(runPasses: 4)
        XCTAssertEqual(b.recordFailure(runPasses: 4), .held(consecutive: 3, announce: true))
    }

    func testThresholdOfOneTripsOnTheFirstFailureOnlyWithEvidence() {
        var b = WorkerCircuitBreaker(threshold: 1)
        XCTAssertEqual(b.recordFailure(runPasses: 0), .held(consecutive: 1, announce: true))
        var c = WorkerCircuitBreaker(threshold: 1)
        _ = c.recordFailure(runPasses: 0)
        XCTAssertEqual(c.recordFailure(runPasses: 1), .trip(consecutive: 2))
    }

    /// 前の run から 2 回落ちていた台は、この run で他レーンが通った後の最初の失敗で離脱する
    func testCarriedFailuresTripOnFirstFailureAfterAnotherLanePassed() {
        var b = WorkerCircuitBreaker(threshold: 3, carriedFailures: 2)
        XCTAssertEqual(b.consecutiveFailures, 2)
        XCTAssertEqual(b.carriedFailures, 2)
        XCTAssertEqual(b.recordFailure(runPasses: 1), .trip(consecutive: 3))
    }

    /// 引き継いでいても、この run で誰も通っていなければ離脱しない(全レーン同時障害の保護は変えない)
    func testCarriedFailuresStillHeldWhenNobodyPassed() {
        var b = WorkerCircuitBreaker(threshold: 3, carriedFailures: 2)
        XCTAssertEqual(b.recordFailure(runPasses: 0), .held(consecutive: 3, announce: true))
        XCTAssertEqual(b.recordFailure(runPasses: 1), .trip(consecutive: 4))
    }

    func testPassClearsCarriedFailures() {
        var b = WorkerCircuitBreaker(threshold: 3, carriedFailures: 2)
        b.recordPass()
        XCTAssertEqual(b.carriedFailures, 0)
        XCTAssertEqual(b.recordFailure(runPasses: 1), .keep)
    }

    /// 持ち越しは前の run からだけ(同じ run の復帰は 0 から数え直す = `testRunWorkerClearsLedgerOnRevive`)
    func testCarriedNoteNamesEarlierRuns() {
        XCTAssertEqual(RunOrchestrator.carriedNote(0), "")
        XCTAssertEqual(RunOrchestrator.carriedNote(3), " (including 3 carried over from earlier runs)")
    }

    /// 復帰の有無は superviseWorker の復帰回数から渡す(渡し忘れると復帰後も前の数を持ち越す)
    func testSupervisorPassesTheRevivedFlag() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FTCore/RunOrchestrator.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(code.contains("runWorker(current, queue: queue, revived: revives > 0)"))
        XCTAssertEqual(code.components(separatedBy: "Self.carriedNote(breaker.carriedFailures)").count - 1, 2)
    }

    /// 起こし直したレーンは台帳を消してから読む = 0 から数え直す(持ち越すと閾値ちょうどで始まり次の1本でまた離脱していた)・配線の固定
    func testRunWorkerClearsLedgerOnRevive() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FTCore/RunOrchestrator.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(code.contains("if revived, let s = laneStreakKey(streakKey) { LaneFailureStreakStore.clear("))
        XCTAssertTrue(code.contains("carriedFailures: revived ? 0 : laneStreakKey(streakKey)"), "消去が失敗しても読まない")
    }

    /// 別のデバイスでも落ちたシナリオは数えない・同じデバイスだけ/記録の無いシナリオは数える・通ったら消える
    func testScenarioFailingOnAnotherDeviceDoesNotCount() {
        var w = ScenarioFailureWitnesses()
        XCTAssertTrue(w.recordFailure(scenario: "A", worker: "android:p1"), "記録の無いシナリオは数える")
        XCTAssertTrue(w.recordFailure(scenario: "A", worker: "android:p1"), "同じデバイスだけで落ちるなら数える")
        XCTAssertFalse(w.recordFailure(scenario: "A", worker: "android:p2"), "別のデバイスでも落ちた")
        XCTAssertFalse(w.recordFailure(scenario: "A", worker: "android:p1"))
        XCTAssertTrue(w.recordFailure(scenario: "B", worker: "android:p1"), "シナリオごと")
        w.recordPass(scenario: "A")
        XCTAssertTrue(w.recordFailure(scenario: "A", worker: "android:p2"), "通った後は1台目から")
        XCTAssertTrue(w.recordFailure(scenario: "A", worker: "ios:x"), "別の OS のデバイスの失敗は根拠にしない")
        XCTAssertFalse(w.recordFailure(scenario: "A", worker: "ios:y"))
    }

    func testScenarioFailureWitnessesPersistPerScope() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sfw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var w = ScenarioFailureWitnesses()
        _ = w.recordFailure(scenario: "A", worker: "ios:x")
        w.save(stateDir: dir, scope: "P 1")
        var loaded = ScenarioFailureWitnesses.load(stateDir: dir, scope: "P 1")
        XCTAssertFalse(loaded.recordFailure(scenario: "A", worker: "ios:y"), "run をまたいで覚えている")
        XCTAssertEqual(ScenarioFailureWitnesses.load(stateDir: dir, scope: "other"), ScenarioFailureWitnesses())
        ScenarioFailureWitnesses().save(stateDir: dir, scope: "P 1")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ScenarioFailureWitnesses.fileURL(stateDir: dir, scope: "P 1").path), "空は消す")
    }

    /// 配線: 失敗はブレーカの前に記録して数えるかを決め、通過は記録を消す(run の経路は単体では通らない)
    func testRunWorkerConsultsFailureWitnesses() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FTCore/RunOrchestrator.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(code.contains("await witnessOutcome(scenario: item.info.id, worker: streakKey, passed: false) {\n"
                                    + "                let verdict = breaker.recordFailure("))
        XCTAssertTrue(code.contains("if outcome == .passed { _ = await witnessOutcome(scenario: item.info.id, worker: streakKey, passed: true) }"),
                      "対象外(notApplicable)は記録を消さない")
    }
}
