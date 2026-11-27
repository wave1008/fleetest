// 対象外の回し直し(DR-214)の子(ScenarioQueue)と親(DynamicDispatcher)をつないだ結合。デバイス不要。
// 破ると: 2台のマシンがそれぞれ別の対象外のシナリオを手元で回し直している最中に、どちらの空いたレーンも親に保留され、
// 手元に戻ったシナリオを取れるレーンが居なくなって run が終わらない(親が保留中のレーンへ `recheck` を返さない・
// 子が回し直し中の未試行のシナリオを待たずに親へ頼む)/ 回し直し中に他のマシンが先に終わって「未試行の台が落ちた」赤になる。

import XCTest
@testable import FTCore
@testable import fleetest

final class NotApplicableMutualHandOnTests: XCTestCase {

    /// 子の配り手を親へ同じプロセスの中でつなぐ(ワイヤの代わり。返事の読み方は StdioPullSource.deliver と同じ)
    private final class Bridge: ScenarioPullSource, @unchecked Sendable {
        // @unchecked の根拠: 可変状態は LockedValue の中。dispatcher は組み立て後に1回だけ入れる
        let entry: Int
        let dispatcher = LockedValue<DynamicDispatcher?>(nil)
        private let waiters = LockedValue<[Int: CheckedContinuation<PullAnswer, Never>]>([:])
        private let nextReq = LockedValue(1)

        init(entry: Int) { self.entry = entry }

        /// 親の返事を待っている要求の数(親に保留されたレーン)
        var waitingCount: Int { waiters.withLock { $0.count } }

        func next(platform: String, lane: String) async -> PullAnswer {
            await withCheckedContinuation { continuation in
                let req = nextReq.withLock { value -> Int in defer { value += 1 }; return value }
                waiters.withLock { $0[req] = continuation }
                if let reply = dispatcher.value?.handle(
                    WorkQueueProtocol.Want(req: req, lane: lane, platform: platform), fromEntry: entry) {
                    deliver(reply)
                }
            }
        }

        func deliver(_ reply: WorkQueueProtocol.Reply) {
            let continuation = waiters.withLock { $0.removeValue(forKey: reply.req) }
            if reply.again == true {
                continuation?.resume(returning: .recheck)
            } else {
                continuation?.resume(returning: reply.unit.map(PullAnswer.unit) ?? .exhausted)
            }
        }

        func stopWaiting() {}

        func declareNotApplicable(platform: String, lane: String, unit: ScenarioUnitKey,
                                  departedUntried: Bool, kinds: Set<String>) async -> NotApplicableHandoff.Verdict {
            let reply = dispatcher.value?.handleNotApplicable(
                WorkQueueProtocol.NotApplicable(req: 0, unit: unit, lane: lane, platform: platform, dep: departedUntried, kinds: kinds),
                fromEntry: entry)
            return reply?.verdict.flatMap(NotApplicableHandoff.Verdict.init(wire:)) ?? .skipped
        }

        func noteKept(unit: ScenarioUnitKey, on: Bool) {
            dispatcher.value?.handleKept(WorkQueueProtocol.Kept(unit: unit, on: on), fromEntry: entry)
        }
    }

    private func item(_ id: String) -> ScenarioRunItem {
        ScenarioRunItem(info: ScenarioInfo(id: id, title: id, platform: "ios"), variant: nil)
    }

    private typealias Finals = LockedValue<[String: NotApplicableHandoff.Verdict]>

    /// どの台でも対象外になるシナリオを走らせるレーン(RunOrchestrator.resolveNotApplicable と同じ順: 機械の中 → 親)。
    /// `first` = 先に配られていた1本(宣言してから次を取りに行く)
    private static func runLane(_ lane: String, first: ScenarioRunItem?, queue: ScenarioQueue, bridge: Bridge,
                                finals: Finals) async {
        func declare(_ got: ScenarioRunItem) async {
            let local = await queue.noteNotApplicable(got, lane: lane, reason: "needs a foldable device")
            if local == .handOn { return }
            let verdict = await bridge.declareNotApplicable(
                platform: "ios", lane: lane, unit: got.unitKey, departedUntried: await queue.hasDepartedUntried(got),
                kinds: await queue.triedKinds(got))
            if verdict != .handOn { finals.withLock { $0[got.info.id] = verdict } }
        }
        if let first { await declare(first) }
        while let got = await queue.next(lane: lane) { await declare(got) }
        _ = await queue.laneEnded(lane)
    }

    /// 1台のマシン(子)。全レーンが終わったら親へ子の終わりを知らせる。
    /// 空いたレーン(lanes[1])が親に保留されるのを待ってから、配られていた1本を対象外と宣言する(回し直しより先に保留が
    /// 始まる形 = 保留中のレーンが手元に戻った item を取れない形。宣言が先だと空いたレーンが手元で取ってしまい、待ち合いが起きない)
    private static func runMachine(entry: Int, first: ScenarioRunItem, lanes: [String], queue: ScenarioQueue,
                                   bridge: Bridge, dispatcher: DynamicDispatcher, finals: Finals,
                                   bothHeld: @escaping @Sendable () async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await runLane(lanes[1], first: nil, queue: queue, bridge: bridge, finals: finals) }
            group.addTask {
                await bothHeld()
                await runLane(lanes[0], first: first, queue: queue, bridge: bridge, finals: finals)
            }
        }
        dispatcher.childExited(entry: entry)
    }

    /// 2台のマシンがそれぞれ別の対象外のシナリオを手元で回し直す: 待ち合わずに終わり、全台が試した対象外(緑)で確定する
    func testTwoMachinesHandingOnLocallyAtOnceFinishWithoutWaitingOnEachOther() async throws {
        let ids = ["Fold.S1", "Fold.S2"]
        let bridges = [Bridge(entry: 0), Bridge(entry: 1)]
        let dispatcher = DynamicDispatcher(
            scenarios: ids.map { DynamicSplit.Scenario(id: $0, variant: nil, platform: "ios") },
            estimateMs: { _, _ in 1000 }, lpt: true,
            entryPlatforms: [0: ["ios"], 1: ["ios"]],
            entryKinds: { _ in [:] },
            send: { entry, reply in bridges[entry].deliver(reply) })
        for bridge in bridges { bridge.dispatcher.withLock { $0 = dispatcher } }
        let queues = bridges.map { bridge -> ScenarioQueue in
            let catalog = Dictionary(uniqueKeysWithValues: ids.map { (ScenarioUnitKey(id: $0, variant: nil), [item($0)]) })
            return ScenarioQueue(pulled: ScenarioQueue.PullState(
                source: bridge, platform: "ios", catalog: LockedValue(catalog), onHandOut: { _ in }, onUnknownID: { _ in }))
        }
        let lanes = [["a0", "b0"], ["a1", "b1"]]
        for (queue, names) in zip(queues, lanes) { for name in names { await queue.laneJoined(name) } }

        // 1本ずつ別のマシンへ配らせてから(互いに回し直す形)、残りのレーンを走らせる
        let got0 = await queues[0].next(lane: "a0")
        let got1 = await queues[1].next(lane: "a1")
        let first0 = try XCTUnwrap(got0)
        let first1 = try XCTUnwrap(got1)
        XCTAssertNotEqual(first0.info.id, first1.info.id)

        let finals = Finals([:])
        let finished = LockedValue(false)
        let firsts = [first0, first1]
        let bothHeld: @Sendable () async -> Void = {
            for _ in 0..<200 where bridges.contains(where: { $0.waitingCount == 0 }) {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        let run = Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for entry in 0..<2 {
                    group.addTask {
                        await NotApplicableMutualHandOnTests.runMachine(
                            entry: entry, first: firsts[entry], lanes: lanes[entry], queue: queues[entry],
                            bridge: bridges[entry], dispatcher: dispatcher, finals: finals, bothHeld: bothHeld)
                    }
                }
            }
            finished.withLock { $0 = true }
        }
        for _ in 0..<150 where !finished.value { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(bridges.map(\.waitingCount).filter { $0 > 0 }.count, 0, "親に保留されたまま残ったレーンがある")
        XCTAssertTrue(finished.value, "2台のマシンが互いの回し直しを待ち合って終わらない")
        run.cancel()
        XCTAssertEqual(finals.value, ["Fold.S1": .skipped, "Fold.S2": .skipped], "全台が試した対象外は対象外(緑)で確定する")
    }
}
