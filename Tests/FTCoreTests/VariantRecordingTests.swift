// バリアント(シナリオ × バリアントの単位)の記録・`--failed`・JUnit・LPT・失敗の目撃の鍵。
// この段ではプロファイルの variants を受け付けないので、variant を手で入れて形を固定する。
// variant が nil の記録は今と1バイトも変わらない(欄ごと省く = DR-75)ことも同じ場で確かめる。

import XCTest
@testable import FTCore

final class VariantRecordingTests: XCTestCase {

    private var root: URL!
    private var stateDir: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-variant-recording-\(UUID().uuidString)")
        stateDir = root.appendingPathComponent("last-results")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func unit(_ id: String, _ variant: String?) -> ScenarioUnitKey { ScenarioUnitKey(id: id, variant: variant) }

    private func record(_ id: String, variant: String?, passed: Bool = true, worker: String? = nil,
                        durationMs: Int = 1000) -> ScenarioRunRecord {
        ScenarioRunRecord(scenarioID: id, variant: variant, platform: "ios", worker: worker, passed: passed,
                          startedAt: "2026-11-22T00:00:00Z", durationMs: durationMs,
                          steps: StepCountsRecord(total: 1, passed: passed ? 1 : 0, failed: passed ? 0 : 1))
    }

    // MARK: 記録の形

    func testVariantIsOmittedFromJSONWhenNilAndPresentWhenSet() throws {
        let encoder = JSONEncoder()
        let plain = String(decoding: try encoder.encode(record("A.one", variant: nil)), as: UTF8.self)
        XCTAssertFalse(plain.contains("variant"))
        let dark = String(decoding: try encoder.encode(record("A.one", variant: "dark")), as: UTF8.self)
        XCTAssertTrue(dark.contains("\"variant\":\"dark\""))
        let decoded = try JSONDecoder().decode(ScenarioRunRecord.self, from: Data(dark.utf8))
        XCTAssertEqual(decoded.unitKey, unit("A.one", "dark"))
        var event = ScenarioEvent(kind: "step")
        event.scenario = "A.one"
        XCTAssertFalse(event.encodedLine().contains("variant"))
        event.variant = "dark"
        XCTAssertTrue(event.encodedLine().contains("\"variant\":\"dark\""))
    }

    // MARK: 結果のファイル名

    func testFileNameCarriesVariantAndDiscardLastIsPerUnitAndWorker() throws {
        let recorder = RunRecorder.begin(project: TestProject(name: "P", rootURL: root), profile: "ios", trigger: "test",
                                         captureHostMetrics: false, declaredVariants: ["dark", "light"])
        XCTAssertEqual(recorder.record(record("A.one", variant: nil)), "A.one")
        XCTAssertEqual(recorder.record(record("A.one", variant: "dark", worker: "ios:a")), "A.one@dark")
        XCTAssertEqual(recorder.record(record("A.one", variant: "light", worker: "ios:a")), "A.one@light")
        // 同じ単位の2回目は連番(~2)。別のバリアントとは混ざらない
        XCTAssertEqual(recorder.record(record("A.one", variant: "dark", worker: "ios:b")), "A.one@dark~2")
        // 取り消しは (単位, worker): dark の ios:a だけが退避され、light と variant 無しは残る
        recorder.discardLast(unit: unit("A.one", "dark"), worker: "ios:a")
        let names = Set(RunResultsStore.records(runDir: recorder.runDir).map { "\($0.scenarioID)|\($0.variant ?? "-")|\($0.worker ?? "-")" })
        XCTAssertEqual(names, ["A.one|-|-", "A.one|light|ios:a", "A.one|dark|ios:b"])
    }

    func testRunMetaCarriesDeclaredVariantsOnlyWhenDeclared() {
        let with = RunRecorder.begin(project: TestProject(name: "P", rootURL: root), profile: "ios", trigger: "test",
                                     captureHostMetrics: false, declaredVariants: ["dark", "light"])
        XCTAssertEqual(RunResultsStore.meta(runDir: with.runDir)?.variants, ["dark", "light"])
        let without = RunRecorder.begin(project: TestProject(name: "P", rootURL: root), profile: "ios", trigger: "test",
                                        captureHostMetrics: false)
        XCTAssertNil(RunResultsStore.meta(runDir: without.runDir)?.variants)
    }

    // MARK: --failed の記録

    func testUnitRecordsLiveUnderVariantsDirAndIDRecordIsAggregated() {
        let declared = ["dark", "light"]
        LastResultsStore.record(stateDir: stateDir, unit: unit("A.one", "dark"), passed: true, runID: "r1", declaredVariants: declared)
        XCTAssertEqual(try? String(contentsOf: stateDir.appendingPathComponent("A.one"), encoding: .utf8), "passed")
        LastResultsStore.record(stateDir: stateDir, unit: unit("A.one", "light"), passed: false, runID: "r1", declaredVariants: declared)
        XCTAssertEqual(try? String(contentsOf: stateDir.appendingPathComponent("A.one"), encoding: .utf8), "failed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateDir.appendingPathComponent("variants/dark/A.one").path))
        XCTAssertEqual(LastResultsStore.failedIDs(stateDir: stateDir, declaredVariants: declared), [unit("A.one", "light")])
        // light が直ったら集約も passed へ作り直される
        LastResultsStore.record(stateDir: stateDir, unit: unit("A.one", "light"), passed: true, runID: "r2", declaredVariants: declared)
        XCTAssertEqual(try? String(contentsOf: stateDir.appendingPathComponent("A.one"), encoding: .utf8), "passed")
        XCTAssertEqual(LastResultsStore.failedIDs(stateDir: stateDir, declaredVariants: declared), [])
    }

    func testFailedWinsWithinOneRunButNotAcrossRuns() {
        let declared = ["dark"]
        // --broadcast: 同じ run で同じ単位を2台が書く。後の passed で failed を消さない
        LastResultsStore.record(stateDir: stateDir, unit: unit("A.one", "dark"), passed: false, runID: "r1", declaredVariants: declared)
        LastResultsStore.record(stateDir: stateDir, unit: unit("A.one", "dark"), passed: true, runID: "r1", declaredVariants: declared)
        XCTAssertEqual(LastResultsStore.failedIDs(stateDir: stateDir, declaredVariants: declared), [unit("A.one", "dark")])
        // 次の run の passed は直近の結果として上書きする
        LastResultsStore.record(stateDir: stateDir, unit: unit("A.one", "dark"), passed: true, runID: "r2", declaredVariants: declared)
        XCTAssertEqual(LastResultsStore.failedIDs(stateDir: stateDir, declaredVariants: declared), [])
    }

    func testNilVariantWritesTheIDRecordAsBeforeAndVariantsDirIsNotAnID() {
        LastResultsStore.record(stateDir: stateDir, unit: unit("A.one", nil), passed: false, runID: "r1", declaredVariants: [])
        XCTAssertEqual(try? String(contentsOf: stateDir.appendingPathComponent("A.one"), encoding: .utf8), "failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateDir.appendingPathComponent("variants").path))
        // variants/ が残っていても variants の宣言が無ければ読まない・数えない
        LastResultsStore.record(stateDir: stateDir, unit: unit("B.two", "dark"), passed: false, runID: "r1", declaredVariants: ["dark"])
        XCTAssertEqual(LastResultsStore.failedIDs(stateDir: stateDir, declaredVariants: []), [unit("A.one", nil), unit("B.two", nil)],
                       "宣言なしは ID の記録だけを variant nil の単位として読む(B.two は集約)")
        XCTAssertEqual(LastResultsStore.recordedCount(stateDir: stateDir), 2, "variants ディレクトリは ID に数えない")
    }

    // MARK: JUnit

    func testJUnitCaseNameHasVariantAndBroadcastAddsWorker() {
        let plain = JUnitReportWriter.xml(project: "P", records: [record("A.one", variant: nil, worker: "ios:a")])
        XCTAssertTrue(plain.contains("name=\"one\""))
        let variants = JUnitReportWriter.xml(project: "P", records: [
            record("A.one", variant: "dark", worker: "ios:a"), record("A.one", variant: "light", worker: "ios:a")])
        XCTAssertTrue(variants.contains("name=\"one[dark]\""))
        XCTAssertTrue(variants.contains("name=\"one[light]\""))
        XCTAssertFalse(variants.contains("(ios:a)"), "同じ単位が1台でしか回っていなければ端末は入れない")
        let broadcast = JUnitReportWriter.xml(project: "P", records: [
            record("A.one", variant: "dark", worker: "ios:a"), record("A.one", variant: "dark", worker: "ios:b")])
        XCTAssertTrue(broadcast.contains("name=\"one[dark] (ios:a)\""))
        XCTAssertTrue(broadcast.contains("name=\"one[dark] (ios:b)\""))
    }

    // MARK: LPT・見積り・目撃

    func testLPTFallsBackToVariantlessHistoryAndPrefersTheVariantsOwn() {
        let info = ScenarioInfo(id: "A.one", title: "t", platform: "ios")
        let other = ScenarioInfo(id: "A.two", title: "t", platform: "ios")
        let items = [ScenarioRunItem(info: other, variant: nil), ScenarioRunItem(info: info, variant: "dark")]
        // dark の履歴が無い: variant 無しの履歴(A.one = 1000 < A.two = 5000)を使う → A.two が先
        // (履歴が無いものは先頭へ回るので、フォールバックが効かなければ A.one が先になる)
        let fallback = LPTScheduler.order(items, durations: [
            .init(scenarioID: "A.one", platform: "ios", medianMs: 1000), .init(scenarioID: "A.two", platform: "ios", medianMs: 5000)],
            defaultPlatform: "ios")
        XCTAssertEqual(fallback.map(\.unitKey), [unit("A.two", nil), unit("A.one", "dark")])
        // dark 自身の履歴(9000)が variant 無し(1000)に勝つ → A.one が先
        let own = LPTScheduler.order(items, durations: [
            .init(scenarioID: "A.one", platform: "ios", medianMs: 1000), .init(scenarioID: "A.one", variant: "dark", platform: "ios", medianMs: 9000),
            .init(scenarioID: "A.two", platform: "ios", medianMs: 5000)], defaultPlatform: "ios")
        XCTAssertEqual(own.map(\.unitKey), [unit("A.one", "dark"), unit("A.two", nil)])
    }

    func testDurationsKeepVariantsApart() {
        let rows = LPTScheduler.durations(from: [record("A.one", variant: "dark", durationMs: 400),
                                                 record("A.one", variant: nil, durationMs: 100)])
        XCTAssertEqual(Set(rows.map { "\($0.variant ?? "-"):\(Int($0.medianMs))" }), ["dark:400", "-:100"])
    }

    func testFailureWitnessesDoNotMixVariants() {
        var witnesses = ScenarioFailureWitnesses()
        XCTAssertTrue(witnesses.recordFailure(unit: unit("A.one", "dark"), worker: "ios:a"))
        // 別のバリアントの失敗は「別のデバイスでも落ちている」の材料にしない(同じ単位だけが証拠)
        XCTAssertTrue(witnesses.recordFailure(unit: unit("A.one", "light"), worker: "ios:b"))
        XCTAssertFalse(witnesses.recordFailure(unit: unit("A.one", "dark"), worker: "ios:b"))
    }

    func testSummaryAndSlowRowsAreSeparatedPerVariant() {
        let records = [record("A.one", variant: "dark", passed: false), record("A.one", variant: "light"),
                       record("A.one", variant: nil)]
        let rows = RunResultsQuery.scenarioSummary(records, recentRuns: 10)
        XCTAssertEqual(Set(rows.map { "\($0.variant ?? "-"):\(Int($0.successRate))" }), ["dark:0", "light:100", "-:100"])
        XCTAssertEqual(RunResultsQuery.slowTests(records, limit: 10, recentRuns: 10).count, 3)
    }
}
