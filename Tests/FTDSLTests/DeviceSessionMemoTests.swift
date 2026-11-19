import XCTest
@testable import FTDSL
import FTCore

/// デバイスセッション(run メモ + setUpDevice)の子側。親への通知イベントと、親が渡す `runSetUpDevice` への従い方を固定する。
final class DeviceSessionMemoTests: XCTestCase {

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ScenarioEvent] = []
        func add(_ event: ScenarioEvent) { lock.lock(); items.append(event); lock.unlock() }
        var events: [ScenarioEvent] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private final class NullDriver: AppDriver {
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws -> String? { nil }
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
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

    private func makeCore(sink: Sink, runSetUpDevice: Bool = true) -> FTDriveCore {
        let core = FTDriveCore(driver: NullDriver(), platform: "ios", app: "com.example.app",
                               scenarioID: "T.S0010", scenarioTitle: "t",
                               delegate: nil, healingEnabled: false, tunables: RunTunables(), dryRun: true,
                               fingerprintCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                                   .appendingPathComponent("ft-memo-test.json"),
                               emit: { sink.add($0) })
        core.runSetUpDevice = runSetUpDevice
        return core
    }

    private func steps(_ core: FTDriveCore) -> [DSLStepRecord] {
        core.finalRecord.scenes.flatMap(\.steps)
    }

    private func setUpDeviceStatuses(_ sink: Sink) -> [String] {
        sink.events.filter { $0.kind == "deviceSetUp" }.compactMap(\.status)
    }

    func testRunSetUpDeviceFalseSkipsBodyAndEmitsNothing() {
        let sink = Sink()
        let core = makeCore(sink: sink, runSetUpDevice: false)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        var ran = false
        ftRunSetUpDevice { ran = true }
        XCTAssertFalse(ran)
        XCTAssertEqual(setUpDeviceStatuses(sink), [])
    }

    func testSetUpDeviceEmitsBeganThenPassedAndRecordsSection() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        // setUpDevice での書き込みは失敗になる(DR-207)ので、区切りの記録は読み込みで確かめる
        ftRunSetUpDevice { _ = readRunMemo("k") }
        XCTAssertEqual(setUpDeviceStatuses(sink), ["began", "passed"])
        XCTAssertEqual(steps(core).first?.section, "setUpDevice")
    }

    func testFailingSetUpDeviceEmitsFailed() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        ftRunSetUpDevice { core.scenarioAborted = true }
        XCTAssertEqual(setUpDeviceStatuses(sink), ["began", "failed"])
    }

    func testAlreadyAbortedScenarioDoesNotRunSetUpDevice() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        core.scenarioAborted = true
        var ran = false
        ftRunSetUpDevice { ran = true }
        XCTAssertFalse(ran)
        XCTAssertEqual(setUpDeviceStatuses(sink), [])
    }

    private func memoEvents(_ sink: Sink) -> [ScenarioEvent] {
        sink.events.filter { $0.kind.lowercased().contains("memo") }
    }

    func testWriteRunMemoEmitsAndReadRunMemoReturnsLastValue() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        writeRunMemo("k", "first")
        writeRunMemo("k", "second")
        XCTAssertEqual(readRunMemo("k"), "second")
        let writes = sink.events.filter { $0.kind == "runMemoWrite" }
        XCTAssertEqual(writes.map { $0.memoKey }, ["k", "k"])
        XCTAssertEqual(writes.map { $0.memoValue }, ["first", "second"])
        XCTAssertEqual(steps(core).map(\.description),
                       ["writeRunMemo \"k\" = \"first\"", "writeRunMemo \"k\" = \"second\"", "readRunMemo \"k\" → \"second\""])
    }

    /// test 範囲のメモは親へ何も出さず、run メモとも混ざらない
    func testTestMemoEmitsNothingAndIsSeparateFromRunMemo() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        writeMemo("k", "first")
        writeMemo("k", "second")
        XCTAssertEqual(readMemo("k"), "second")
        "s".memoTextAs("t")
        clearMemo()
        XCTAssertEqual(readMemo("k"), "")
        XCTAssertTrue(memoEvents(sink).isEmpty)
        XCTAssertTrue(core.runMemo.isEmpty)
        writeRunMemo("k", "run")
        XCTAssertEqual(readMemo("k"), "", "run メモの値が test 範囲のメモから見えている")
        XCTAssertEqual(readRunMemo("k"), "run")
    }

    func testHandedOverRunMemoIsReadableAndTestMemoStartsEmpty() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        core.runMemo = ["k": ["a", "b"]]
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        XCTAssertEqual(readRunMemo("k"), "b")
        XCTAssertEqual(readMemo("k"), "")
    }

    func testReadRunMemoOfAbsentKeyReturnsEmptyWithNote() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        XCTAssertEqual(readRunMemo("nope"), "")
        let step = sink.events.last { $0.kind == "step" }
        XCTAssertEqual(step?.notes, [StepNote.runMemoKeyNotFound.rawValue])
        XCTAssertEqual(step?.status, "passed")
    }

    func testReadMemoOfAbsentKeyReturnsEmptyWithTestNote() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        XCTAssertEqual(readMemo("nope"), "")
        let step = sink.events.last { $0.kind == "step" }
        XCTAssertEqual(step?.notes, [StepNote.memoKeyNotFound.rawValue])
        XCTAssertEqual(step?.status, "passed")
    }

    func testClearRunMemoEmptiesAndEmits() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        writeRunMemo("k", "v")
        clearRunMemo()
        XCTAssertEqual(readRunMemo("k"), "")
        XCTAssertEqual(sink.events.filter { $0.kind == "runMemoClear" }.count, 1)
    }

    func testStringMemoTextAsWritesAndReturnsTheString() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        XCTAssertEqual("hello".memoTextAs("g"), "hello")
        XCTAssertEqual(readMemo("g"), "hello")
        XCTAssertEqual("world".runMemoTextAs("r"), "world")
        XCTAssertEqual(readRunMemo("r"), "world")
        XCTAssertEqual(sink.events.filter { $0.kind == "runMemoWrite" }.compactMap(\.memoValue), ["world"])
    }

    private func element(label: String?, value: String?) -> FTElement {
        FTElement(selector: FTSelector.parse("#x"),
                  matched: ElementInfo(ref: 1, type: "textField", identifier: "x", label: label, value: value,
                                       placeholder: nil, enabled: true,
                                       frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 1))
    }

    /// 空のラベルは「無い」扱いで値へ進む(入力欄はラベル "" で値に文字を持つ)
    func testElementMemoTextAsSkipsEmptyLabel() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        element(label: "", value: "abc").runMemoTextAs("field")
        element(label: "Total", value: "9").runMemoTextAs("total")
        element(label: nil, value: nil).runMemoTextAs("blank")
        element(label: "", value: "abc").memoTextAs("tfield")
        XCTAssertEqual(readRunMemo("field"), "abc")
        XCTAssertEqual(readRunMemo("total"), "Total")
        XCTAssertEqual(core.runMemo["blank"], [""])
        XCTAssertEqual(readMemo("tfield"), "abc")
        XCTAssertEqual(sink.events.filter { $0.kind == "runMemoWrite" }.compactMap(\.memoValue), ["abc", "Total", ""])
    }

    func testAbortedScenarioSkipsMemoCommandsAndEmitsNothing() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        core.scenarioAborted = true
        writeMemo("k", "v")
        clearMemo()
        writeRunMemo("k", "v")
        clearRunMemo()
        XCTAssertEqual(readMemo("k"), "")
        XCTAssertEqual(readRunMemo("k"), "")
        XCTAssertTrue(memoEvents(sink).isEmpty)
        XCTAssertTrue(core.runMemo.isEmpty)
        XCTAssertTrue(core.testMemo.isEmpty)
        XCTAssertTrue(steps(core).allSatisfy {
            if case .skipped = $0.status { return true } else { return false }
        })
    }
}
