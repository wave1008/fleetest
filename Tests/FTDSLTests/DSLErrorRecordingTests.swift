// B3 レビューの直し: コマンド引数の断りの failureKind・中断後の ifCanSelect / repeatWhileCanSelect の skip・
// thisIs(nil) と文字列 "nil"・endResponseMeasurement の排他(ソース走査)。

import XCTest
@testable import FTDSL
@testable import FTCore

final class DSLErrorRecordingTests: XCTestCase {

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ScenarioEvent] = []
        func add(_ event: ScenarioEvent) { lock.lock(); items.append(event); lock.unlock() }
        var steps: [ScenarioEvent] { lock.lock(); defer { lock.unlock() }; return items.filter { $0.kind == "step" } }
    }

    private final class SnapshotCountingDriver: AppDriver {
        private let count = LockedValue(0)
        var snapshots: Int { count.value }
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws -> String? { nil }
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { true }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            count.withLock { $0 += 1 }
            return SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
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

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-dsl-b3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func run(dryRun: Bool = false, _ body: @escaping (FTDriveCore) -> Void) -> (Sink, SnapshotCountingDriver, FTDriveCore) {
        let sink = Sink()
        let driver = SnapshotCountingDriver()
        let core = FTDriveCore(driver: driver, platform: "android", app: "com.example.app",
                               scenarioID: "T.S0010", scenarioTitle: "t",
                               delegate: nil, healingEnabled: false, tunables: RunTunables(),
                               visionClassifierProjectRoot: dir, dryRun: dryRun,
                               fingerprintCacheURL: dir.appendingPathComponent("fp.json"),
                               emit: { sink.add($0) })
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        scenario { scene(1, "s") { action { body(core) } } }
        return (sink, driver, core)
    }

    // MARK: - failureKind

    /// 引数の断り(空の type)は argumentRejected。selectorSyntax に丸めない
    func testEmptyTypeIsArgumentRejected() {
        let (sink, _, _) = run { _ in type("") }
        let step = sink.steps.first { $0.command == "type" }
        XCTAssertEqual(step?.status, "failed")
        XCTAssertEqual(step?.failureKind, StepFailureKind.argumentRejected.rawValue)
    }

    /// セレクタの構文誤りは selectorSyntax のまま(終点セレクタ・ifCanSelect の構文誤りも)
    func testSelectorSyntaxErrorsKeepSelectorSyntaxKind() {
        let (sink, _, _) = run { _ in
            swipeElementToElement("#a", "<通知>:rigthSwitch")
        }
        XCTAssertEqual(sink.steps.first { $0.command == "swipeElementToElement" }?.failureKind,
                       StepFailureKind.selectorSyntax.rawValue)
        let (sink2, _, _) = run { _ in ifCanSelect("<通知>:rigthSwitch") {} }
        XCTAssertEqual(sink2.steps.first { $0.command == "ifCanSelect" }?.failureKind,
                       StepFailureKind.selectorSyntax.rawValue)
    }

    // MARK: - 中断後の ifCanSelect

    func testIfCanSelectAfterAbortIsSkippedWithoutNotMetOrReadingTheScreen() {
        var ran = false
        let (sink, driver, core) = run { core in
            core.scenarioAborted = true
            ifCanSelect("#dialog") { ran = true }
            repeatWhileCanSelect("#dialog") { ran = true }
        }
        XCTAssertFalse(ran)
        XCTAssertEqual(driver.snapshots, 0, "中断後は画面を読まない")
        for command in ["ifCanSelect", "repeatWhileCanSelect"] {
            let step = sink.steps.first { $0.command == command }
            XCTAssertEqual(step?.status, "skipped", command)
            XCTAssertEqual(step?.detail, core.skipReason, "\(command): 中断の理由で skip(not met にしない)")
            XCTAssertFalse(step?.description?.contains("not met") ?? true, command)
        }
        XCTAssertFalse(core.finalRecord.fixSuggestions.contains { $0.message.contains("never matched") },
                       "中断による飛ばしを「セレクタが古い」と提案しない")
    }

    // MARK: - thisIs(nil)

    func testThisIsNilDoesNotMatchStringNil() {
        func failed(_ body: @escaping () -> Void) -> Bool {
            let (sink, _, _) = run { _ in body() }
            return sink.steps.contains { $0.status == "failed" }
        }
        let nilValue: String? = nil
        XCTAssertTrue(failed { ("nil" as String?).thisIs(nil) }, "文字列 \"nil\" は nil と一致しない")
        XCTAssertFalse(failed { nilValue.thisIs(nil) }, "nil 同士は一致")
        XCTAssertFalse(failed { ("nil" as String?).thisIsNot(nil) }, "thisIsNot(nil) も同じ規則")
        XCTAssertTrue(failed { nilValue.thisIsNot(nil) })
    }

    // MARK: - endResponseMeasurement の排他(ソース走査)

    func testEndResponseMeasurementTouchesStateUnderLock() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FTDSL/FTRuntime.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "public func endResponseMeasurement() async {"))
        let body = String(source[start.upperBound...].prefix(900))
        XCTAssertTrue(body.contains("withState {"), "await の後の record / pendingReadyStepIndex は withState で包む")
        XCTAssertFalse(body.contains("\n        record.scenes.applyReadyUpdate"), "ロックの外で record を触らない")
    }
}
