// 台の条件(DR-237)の結論: 合う台が無いまま残った item は、読めなかった台があれば失敗・全台が読めて合わなければ対象外(緑)。
// 実際のデバイスは加わらない(ドレインの結論の関数を本物の RunOrchestrator で通す)。
import XCTest
@testable import FTCore

private struct NoteUnusedDriver: AppDriver {
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "-", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws -> String? { nil }
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { false }
    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 0, height: 0),
                         elements: [], truncatedCount: 0)
    }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}

final class RunOrchestratorDeviceRequirementTests: XCTestCase {
    private let fold = DeviceRequirementSet(required: [.foldable])
    private func traits(foldable: Bool?) -> DeviceTraits {
        DeviceTraits(platform: "ios", physical: false, foldable: foldable, homeButton: false, osVersion: "iOS 27.2", model: "iPhone")
    }
    private func item(_ id: String, requires: DeviceRequirementSet? = nil) -> ScenarioRunItem {
        ScenarioRunItem(info: ScenarioInfo(id: id, title: id, platform: "ios", deviceRequirements: requires), variant: nil)
    }
    private struct Fixture {
        let orchestrator: RunOrchestrator
        let recorder: RunRecorder
    }
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunOrchestratorDeviceRequirementTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let project = TestProject(name: "DeviceGap", rootURL: root)
        let recorder = RunRecorder.begin(project: project, profile: nil, trigger: "test", captureHostMetrics: false)
        let orchestrator = RunOrchestrator(
            project: project, workers: [], settings: ScenarioExecutionSettings(fm: FMConfig(enabled: false)),
            reportDir: root.appendingPathComponent("reports"), recorder: recorder, progressHistoryRuns: 1,
            clearResidualSystemAlert: nil)
        return Fixture(orchestrator: orchestrator, recorder: recorder)
    }
    private func records(_ recorder: RunRecorder) throws -> [ScenarioRunRecord] {
        let dir = recorder.runDir.appendingPathComponent("scenarios")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return try names.filter { $0.hasSuffix(".json") }.map {
            try JSONDecoder().decode(ScenarioRunRecord.self, from: Data(contentsOf: dir.appendingPathComponent($0)))
        }
    }
    private func nextEvents(_ orchestrator: RunOrchestrator, _ count: Int) async -> [RunEvent] {
        var iterator = orchestrator.events.makeAsyncIterator()
        var out: [RunEvent] = []
        for _ in 0..<count { if let e = await iterator.next() { out.append(e) } }
        return out
    }

    /// 全台が読めてどれも合わない = 対象外(緑)。失敗に数えず(0)、`notApplicable` として記録し、サマリの数に入る
    func testAllReadableAndNoneFitsIsAGreenNotApplicable() async throws {
        let f = try fixture()
        let queue = ScenarioQueue([])
        await queue.laneJoined("a", traits: traits(foldable: false))
        await queue.laneJoined("b", traits: traits(foldable: false))
        let counted = await f.orchestrator.concludeDeviceRequirementGap(
            item("C.S0010", requires: fold), queue: queue, platform: "ios", worker: nil, perDevice: false)
        XCTAssertEqual(counted, 0)
        XCTAssertEqual(f.orchestrator.deviceGapSkipped.value, 1)
        let record = try XCTUnwrap(records(f.recorder).first)
        XCTAssertEqual(record.skipKind, .notApplicable)
        XCTAssertTrue(record.passed)
        XCTAssertTrue(record.skipReason?.contains("no matching device") == true, "\(record.skipReason ?? "")")
        XCTAssertTrue(record.skipReason?.contains(".foldable") == true)
        let events = await nextEvents(f.orchestrator, 2)
        guard case .flowFinished(_, _, let passed, _, _, _, let reason, _)? = events.last else { return XCTFail("flowFinished expected") }
        XCTAssertTrue(passed)
        XCTAssertNotNil(reason)
    }

    /// 読めなかった台が1台でもあれば失敗(緑にしない)。事実(台と読めなかった性質)を理由に載せる
    func testAnUnreadableLaneMakesItARedWithFacts() async throws {
        let f = try fixture()
        let queue = ScenarioQueue([])
        await queue.laneJoined("a", traits: traits(foldable: false))
        await queue.laneJoined("blind", traits: traits(foldable: nil))
        let counted = await f.orchestrator.concludeDeviceRequirementGap(
            item("C.S0010", requires: fold), queue: queue, platform: "ios", worker: nil, perDevice: false)
        XCTAssertEqual(counted, 1)
        XCTAssertEqual(f.orchestrator.deviceGapSkipped.value, 0)
        let record = try XCTUnwrap(records(f.recorder).first)
        XCTAssertEqual(record.skipKind, .noWorker)
        XCTAssertFalse(record.passed)
        let reason = try XCTUnwrap(record.failedSteps?.first?.description)
        XCTAssertTrue(reason.contains("blind: unreadable (foldable)"), reason)
        let events = await nextEvents(f.orchestrator, 1)
        guard case .flowSkipped(_, let skipReason)? = events.first else { return XCTFail("flowSkipped expected") }
        XCTAssertEqual(skipReason, reason)
    }

    /// 合う台がある・条件が無い・台が1つも参加していない = 結論ではない(通常のドレイン)
    func testNoConclusionWhenALaneFitsOrThereIsNoConditionOrNoLane() async throws {
        let f = try fixture()
        let queue = ScenarioQueue([])
        let none = await f.orchestrator.concludeDeviceRequirementGap(
            item("C.S0010", requires: fold), queue: queue, platform: "ios", worker: nil, perDevice: false)
        XCTAssertNil(none, "台が1つも参加していない")
        await queue.laneJoined("duo", traits: traits(foldable: true))
        let fits = await f.orchestrator.concludeDeviceRequirementGap(
            item("C.S0010", requires: fold), queue: queue, platform: "ios", worker: nil, perDevice: false)
        XCTAssertNil(fits, "合う台が居たのに残った(離脱)= 通常のドレインの理由")
        let plain = await f.orchestrator.concludeDeviceRequirementGap(
            item("C.S0020"), queue: queue, platform: "ios", worker: nil, perDevice: false)
        XCTAssertNil(plain)
        XCTAssertTrue(try records(f.recorder).isEmpty)
    }

    /// broadcast: 台ごとに「条件が合わず対象外」(緑)/「読めなかった」(赤)を、そのデバイスの worker で記録する
    func testBroadcastRecordsPerDeviceOutcomes() async throws {
        let f = try fixture()
        let plainQueue = ScenarioQueue([])
        await plainQueue.laneJoined("plain", traits: traits(foldable: false))
        let blindQueue = ScenarioQueue([])
        await blindQueue.laneJoined("blind", traits: traits(foldable: nil))
        let s = item("C.S0010", requires: fold)
        let green = await f.orchestrator.concludeDeviceRequirementGap(
            s, queue: plainQueue, platform: "ios", worker: "ios:plain", perDevice: true)
        let red = await f.orchestrator.concludeDeviceRequirementGap(
            s, queue: blindQueue, platform: "ios", worker: "ios:blind", perDevice: true)
        XCTAssertEqual(green, 0)
        XCTAssertEqual(red, 1)
        let byWorker = Dictionary(uniqueKeysWithValues: try records(f.recorder).map { ($0.worker ?? "", $0) })
        XCTAssertEqual(byWorker["ios:plain"]?.skipKind, .notApplicable)
        XCTAssertTrue(byWorker["ios:plain"]?.skipReason?.contains("conditions not met") == true)
        XCTAssertEqual(byWorker["ios:blind"]?.skipKind, .noWorker)
        XCTAssertTrue(byWorker["ios:blind"]?.failedSteps?.first?.description.contains("unreadable (foldable)") == true)
    }

    /// 宣言に合う台での実行時の対象外は注記する(合わない台・条件の無い item では出さない)
    func testDeclaredMatchNoteOnlyOnAFittingLaneWithConditions() throws {
        let f = try fixture()
        let driverless = { (traits: DeviceTraits?) in
            RunWorker(label: "duo(ios:1)", platform: "ios", driver: NoteUnusedDriver(),
                      connection: DriverConnection(platform: "ios", physical: false), logicalName: "duo",
                      deviceKind: nil, deviceTraits: traits)
        }
        let withNote = f.orchestrator.declaredMatchNote(item: item("S", requires: fold), worker: driverless(traits(foldable: true)),
                                                        declared: "fold")
        XCTAssertTrue(withNote?.contains("declared device conditions matched") == true, "\(withNote ?? "")")
        XCTAssertNil(f.orchestrator.declaredMatchNote(item: item("S", requires: fold), worker: driverless(traits(foldable: false)),
                                                      declared: "fold"))
        XCTAssertNil(f.orchestrator.declaredMatchNote(item: item("S", requires: fold), worker: driverless(nil), declared: "fold"))
        XCTAssertNil(f.orchestrator.declaredMatchNote(item: item("S"), worker: driverless(traits(foldable: true)), declared: "fold"))
    }
}
