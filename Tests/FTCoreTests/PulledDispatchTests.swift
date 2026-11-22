import XCTest
@testable import FTCore

/// `ScenarioDispatch.pulled`: キューは空で始まり、配り手が配った ID だけが item になる
final class PulledDispatchTests: XCTestCase {

    private func item(_ id: String, platform: String = "ios") -> ScenarioRunItem {
        ScenarioRunItem(info: ScenarioInfo(id: id, title: id, platform: platform), variant: nil)
    }

    /// 配り手の偽物。返す ID の列を順に返し、聞かれた (platform, lane) を控える
    private final class FakeSource: ScenarioPullSource {
        private let replies: LockedValue<[String?]>
        let asked = LockedValue<[String]>([])
        init(_ replies: [String?]) { self.replies = LockedValue(replies) }
        func next(platform: String, lane: String) async -> PullAnswer {
            asked.withLock { $0.append("\(platform):\(lane)") }
            return replies.withLock { $0.isEmpty ? nil : $0.removeFirst() }.flatMap { $0 }
                .map { PullAnswer.unit(ScenarioUnitKey(id: $0, variant: nil)) } ?? .exhausted
        }
        let stops = LockedValue(0)
        func stopWaiting() { stops.withLock { $0 += 1 } }
        func declareNotApplicable(platform: String, lane: String, unit: ScenarioUnitKey,
                                  departedUntried: Bool) async -> NotApplicableHandoff.Verdict { .skipped }
        let kept = LockedValue<[String]>([])
        func noteKept(unit: ScenarioUnitKey, on: Bool) { kept.withLock { $0.append("\(unit.id):\(on)") } }
    }

    private func makeQueue(_ catalog: [ScenarioRunItem], source: FakeSource,
                           handedOut: LockedValue<[String]> = LockedValue([]),
                           unknown: LockedValue<[String]> = LockedValue([])) -> ScenarioQueue {
        var map: [ScenarioUnitKey: [ScenarioRunItem]] = [:]
        for item in catalog { map[item.unitKey, default: []].append(item) }
        return ScenarioQueue(pulled: ScenarioQueue.PullState(
            source: source, platform: "ios", catalog: LockedValue(map),
            onHandOut: { item in handedOut.withLock { $0.append(item.info.id) } },
            onUnknownID: { unit in unknown.withLock { $0.append(unit.id) } }))
    }

    func testNothingRunsUntilTheSourceHandsItOut() async {
        let source = FakeSource(["A"])
        let queue = makeQueue([item("A"), item("B")], source: source)
        XCTAssertTrue(source.asked.value.isEmpty, "作っただけで配り手へ聞いている")
        let got = await queue.next(lane: "iPhone 17")
        XCTAssertEqual(got?.info.id, "A")
        XCTAssertEqual(source.asked.value, ["ios:iPhone 17"])
        // B はカタログにあっても配られていないので出ない
        let end = await queue.next(lane: "iPhone 17")
        XCTAssertNil(end)
    }

    func testRequeuedItemRunsLocallyBeforeAskingTheSource() async {
        let source = FakeSource(["B"])
        let queue = makeQueue([item("A"), item("B")], source: source)
        let a = item("A")
        let attempt = await queue.requeue(a)
        XCTAssertEqual(attempt, 1)
        let first = await queue.next(lane: "x")
        XCTAssertEqual(first?.info.id, "A")
        XCTAssertTrue(source.asked.value.isEmpty, "再キューが残っているのに配り手へ聞いた")
        let second = await queue.next(lane: "x")
        XCTAssertEqual(second?.info.id, "B")
        XCTAssertEqual(source.asked.value.count, 1)
    }

    func testSourceNilEndsTheQueueAndIsNotAskedAgain() async {
        let source = FakeSource([nil, "A"])
        let queue = makeQueue([item("A")], source: source)
        let hasBefore = await queue.hasItems()
        XCTAssertTrue(hasBefore, "配り手がまだ nil を返していない間は仕事が来うる")
        let first = await queue.next(lane: "x")
        XCTAssertNil(first)
        let hasAfter = await queue.hasItems()
        XCTAssertFalse(hasAfter)
        let again = await queue.next(lane: "x")
        XCTAssertNil(again)
        XCTAssertEqual(source.asked.value.count, 1, "終わった後に聞き直している")
    }

    /// 返事を待つ間に入った再キューは、返事が none でも拾う(拾わずに nil だと健全なレーンが終わり、ドレインで失敗になる)
    func testRequeueWhileWaitingForTheSourceIsPickedUp() async {
        final class GatedSource: ScenarioPullSource, @unchecked Sendable {
            // @unchecked の根拠: 可変状態は LockedValue の中
            let waiter = LockedValue<CheckedContinuation<ScenarioUnitKey?, Never>?>(nil)
            func next(platform: String, lane: String) async -> PullAnswer {
                await withCheckedContinuation { continuation in waiter.withLock { $0 = continuation } }
                    .map(PullAnswer.unit) ?? .exhausted
            }
            func stopWaiting() {}
            func declareNotApplicable(platform: String, lane: String, unit: ScenarioUnitKey,
                                      departedUntried: Bool) async -> NotApplicableHandoff.Verdict { .skipped }
            func noteKept(unit: ScenarioUnitKey, on: Bool) {}
            func answer(_ unit: ScenarioUnitKey?) { waiter.withLock { $0?.resume(returning: unit); $0 = nil } }
        }
        let source = GatedSource()
        let a = item("A")
        let queue = ScenarioQueue(pulled: ScenarioQueue.PullState(
            source: source, platform: "ios", catalog: LockedValue([a.unitKey: [a]]),
            onHandOut: { _ in }, onUnknownID: { _ in }))
        async let got = queue.next(lane: "healthy")
        for _ in 0..<200 where source.waiter.withLock({ $0 == nil }) { try? await Task.sleep(for: .milliseconds(10)) }
        _ = await queue.requeue(a)
        source.answer(nil)
        let result = await got
        XCTAssertEqual(result?.info.id, "A", "待っている間の再キューを拾っていない")
    }

    func testRequeueAfterExhaustionStillRunsLocally() async {
        let source = FakeSource([nil])
        let queue = makeQueue([item("A")], source: source)
        _ = await queue.next(lane: "x")
        _ = await queue.requeue(item("A"))
        let hasItems = await queue.hasItems()
        XCTAssertTrue(hasItems)
        let got = await queue.next(lane: "x")
        XCTAssertEqual(got?.info.id, "A")
    }

    func testUnknownIDIsReportedAndAskedAgain() async {
        let unknown = LockedValue<[String]>([])
        let handed = LockedValue<[String]>([])
        let source = FakeSource(["NOPE", "A"])
        let queue = makeQueue([item("A")], source: source, handedOut: handed, unknown: unknown)
        let got = await queue.next(lane: "x")
        XCTAssertEqual(got?.info.id, "A")
        XCTAssertEqual(unknown.value, ["NOPE"])
        XCTAssertEqual(handed.value, ["A"], "未知の ID を配った本数に数えている")
    }

    func testSameIDHandedTwiceUsesEachCatalogEntryOnce() async {
        let source = FakeSource(["A", "A", "A"])
        let unknown = LockedValue<[String]>([])
        let queue = makeQueue([item("A"), item("A")], source: source, unknown: unknown)
        _ = await queue.next(lane: "x")
        _ = await queue.next(lane: "x")
        let third = await queue.next(lane: "x")
        XCTAssertNil(third)
        XCTAssertEqual(unknown.value, ["A"], "カタログに無くなった ID は未知として扱う")
    }

    func testDrainTakesLocalLeftoversOnly() async {
        let source = FakeSource(["B"])
        let queue = makeQueue([item("A"), item("B")], source: source)
        _ = await queue.requeue(item("A"))
        let local = await queue.nextLocal()
        XCTAssertEqual(local?.info.id, "A")
        let none = await queue.nextLocal()
        XCTAssertNil(none)
        XCTAssertTrue(source.asked.value.isEmpty, "ドレインが配り手へ聞いている")
    }

    func testSharedQueueIsUnchanged() async {
        let queue = ScenarioQueue([item("A"), item("B")])
        let has = await queue.hasItems()
        XCTAssertTrue(has)
        let a = await queue.next(lane: "ignored")
        let b = await queue.next()
        let end = await queue.next()
        XCTAssertEqual([a?.info.id, b?.info.id], ["A", "B"])
        XCTAssertNil(end)
        let hasAfter = await queue.hasItems()
        XCTAssertFalse(hasAfter, "shared は空になったら hasItems が false")
    }

    // MARK: - RunOrchestrator(ワーカー無し)

    private static func startedTotal(_ orchestrator: RunOrchestrator) async -> Int? {
        var total: Int?
        for await event in orchestrator.events {
            if case .runStarted(let value, _) = event { total = value }
        }
        return total
    }

    /// ワーカーが居ない platform のシナリオは、pulled では失敗に数えない(配られていない = この子のものではない)。
    /// 配り手へも聞かない。total は配られた本数 = 0
    func testPulledWithoutWorkersCountsNothingAndNeverAsksTheSource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PulledDispatchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let orchestrator = RunOrchestrator(
            project: TestProject(name: "Pulled", rootURL: root), workers: [],
            settings: ScenarioExecutionSettings(fm: FMConfig(enabled: false)),
            reportDir: root.appendingPathComponent("reports"),
            progressHistoryRuns: 1, clearResidualSystemAlert: nil)
        let source = FakeSource(["A"])
        async let started = Self.startedTotal(orchestrator)
        let summary = await orchestrator.run(items: [item("A"), item("B")], defaultPlatform: "ios",
                                             dispatch: .pulled(source: source))
        let startedTotal = await started
        XCTAssertEqual(summary.total, 0)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(startedTotal, 0)
        XCTAssertTrue(source.asked.value.isEmpty)
    }

    /// 中断は pulled の配り手の待ちを解く(run の設定より前に来た中断も、後に来た中断も)。
    /// 渡し済みの返事が届かなかったレーンは親の none の相手にならず、子が中断のあと終わらなかった
    func testInterruptStopsThePullSourceWhetherItComesBeforeOrAfterTheRunStarts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PulledDispatchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let orchestrator = RunOrchestrator(
            project: TestProject(name: "Pulled", rootURL: root), workers: [],
            settings: ScenarioExecutionSettings(fm: FMConfig(enabled: false)),
            reportDir: root.appendingPathComponent("reports"),
            progressHistoryRuns: 1, clearResidualSystemAlert: nil)
        let source = FakeSource([])
        orchestrator.requestInterrupt()
        _ = await orchestrator.run(items: [item("A")], defaultPlatform: "ios", dispatch: .pulled(source: source))
        XCTAssertEqual(source.stops.value, 1, "run より前の中断で待ちを解いていない")
        orchestrator.requestInterrupt()
        XCTAssertEqual(source.stops.value, 2, "run が配り手を持った後の中断で待ちを解いていない")
    }

    /// 配られた item を対象外で機械の中の別の台へ回し直したら親へ `kept on` を知らせ、回し直した先で終わったら `kept off` を知らせる
    /// (DR-214 ②。知らせないと親はそのレーンの次の要求で配った単位を忘れ、他のマシンの尽きたレーンを待たずに終わらせる)
    func testLocalHandOnTellsTheParentUntilTheItemSettles() async {
        let source = FakeSource(["Fold"])
        let queue = makeQueue([item("Fold")], source: source)
        await queue.laneJoined("a")
        await queue.laneJoined("b")
        let first = await queue.next(lane: "a")
        XCTAssertEqual(first?.info.id, "Fold")
        let verdict = await queue.noteNotApplicable(item("Fold"), lane: "a", reason: "needs a foldable device")
        XCTAssertEqual(verdict, .handOn)
        XCTAssertEqual(source.kept.value, ["Fold:true"], "機械の中で回し直し始めたことを親へ知らせる")
        // 宣言したレーン a が次を取りに行っても、回し直しの最中なので終わりは知らせない
        let none = await queue.next(lane: "a", shouldStop: { true })
        XCTAssertNil(none)
        XCTAssertEqual(source.kept.value, ["Fold:true"])
        let second = await queue.next(lane: "b")
        XCTAssertEqual(second?.info.id, "Fold")
        // b で走り終えた(次を取りに行った)= 回し直しの終わり
        _ = await queue.next(lane: "b", shouldStop: { true })
        XCTAssertEqual(source.kept.value, ["Fold:true", "Fold:false"])
    }

    /// 回し直し中の item を別のレーンが走らせていて、自分がまだ試していないレーンは親へ頼まず手元で待つ(DR-214 ②)。
    /// 頼むと親に保留されうる = 対象外で手元へ戻ったときに取れず、親の見直し(`recheck`)は回し直しの始まりにしか来ない
    func testUntriedLaneWaitsLocallyWhileAnotherLaneRunsAKeptItem() async {
        let source = FakeSource(["Fold"])
        let queue = makeQueue([item("Fold")], source: source)
        for lane in ["a", "b", "c"] { await queue.laneJoined(lane) }
        _ = await queue.next(lane: "a")
        let verdict = await queue.noteNotApplicable(item("Fold"), lane: "a", reason: "needs a foldable device")
        XCTAssertEqual(verdict, .handOn)
        let taken = await queue.next(lane: "b")
        XCTAssertEqual(taken?.info.id, "Fold")
        let waited = await queue.next(lane: "c", shouldStop: { true })
        XCTAssertNil(waited)
        XCTAssertFalse(source.asked.value.contains("ios:c"), "回し直し中の item を試していないレーンが親へ頼んだ")
    }

    /// 親の `recheck` は尽きの印を付けない(手元を見直してから聞き直す)
    func testRecheckDoesNotExhaustTheLane() async {
        final class RecheckOnce: ScenarioPullSource, @unchecked Sendable {
            // @unchecked の根拠: 可変状態は LockedValue の中
            let answers = LockedValue<[PullAnswer]>([.recheck, .unit(ScenarioUnitKey(id: "A", variant: nil))])
            func next(platform: String, lane: String) async -> PullAnswer {
                answers.withLock { $0.isEmpty ? .exhausted : $0.removeFirst() }
            }
            func stopWaiting() {}
            func declareNotApplicable(platform: String, lane: String, unit: ScenarioUnitKey,
                                      departedUntried: Bool) async -> NotApplicableHandoff.Verdict { .skipped }
            func noteKept(unit: ScenarioUnitKey, on: Bool) {}
        }
        let a = item("A")
        let queue = ScenarioQueue(pulled: ScenarioQueue.PullState(
            source: RecheckOnce(), platform: "ios", catalog: LockedValue([a.unitKey: [a]]),
            onHandOut: { _ in }, onUnknownID: { _ in }))
        let got = await queue.next(lane: "x")
        XCTAssertEqual(got?.info.id, "A", "見直しの返事でレーンが尽きた扱いになった")
    }
}
