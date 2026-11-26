// 判定の足跡(StepTrace)の上限・エンコード・運搬の固定。
import XCTest
@testable import FTCore

final class StepTraceTests: XCTestCase {

    /// 既定値のリテラル固定(他のテストが差し替えると production の既定を1度も通らないため)
    func testDefaultLimitsArePinned() {
        XCTAssertEqual(StepTraceLimits.maxEntries, 16)
        XCTAssertEqual(StepTraceLimits.maxValueLength, 240)
    }

    /// 段の rawValue は永続化される(一度出したものは変えない)
    func testStageRawValuesArePersistedIdentifiers() {
        XCTAssertEqual(StepTraceStage.allCases.map(\.rawValue).sorted(), [
            "container-outside", "keyboard-cover-lift", "ocr-near-miss", "screen-state-publish", "scroll-search-end",
            "trace-truncated",
        ])
    }

    func testEntriesBeyondTheLimitAreDroppedWithATruncationMarker() {
        var buffer = StepTraceBuffer()
        for index in 0..<(StepTraceLimits.maxEntries + 3) {
            buffer.append(.scrollSearchEnd, ["n": String(index)])
        }
        let finished = buffer.finished()
        XCTAssertEqual(finished.count, StepTraceLimits.maxEntries + 1)
        // 古い方から捨てる: 先頭に印・残るのは最後の 16 件(n = 3〜18)
        XCTAssertEqual(finished.first, StepTraceEntry(stage: "trace-truncated", facts: ["dropped": "3"]))
        XCTAssertEqual(finished[1].facts["n"], "3")
        XCTAssertEqual(finished.last?.facts["n"], String(StepTraceLimits.maxEntries + 2))
    }

    func testExactlyTheLimitHasNoMarker() {
        var buffer = StepTraceBuffer()
        for _ in 0..<StepTraceLimits.maxEntries { buffer.append(.containerOutside, ["a": "b"]) }
        XCTAssertEqual(buffer.finished().count, StepTraceLimits.maxEntries)
        XCTAssertFalse(buffer.finished().contains { $0.stage == "trace-truncated" })
    }

    func testLongValuesAreClippedWithAnEllipsis() {
        var buffer = StepTraceBuffer()
        buffer.append(.ocrNearMiss, ["short": "abc", "long": String(repeating: "あ", count: 500)])
        let facts = buffer.finished()[0].facts
        XCTAssertEqual(facts["short"], "abc")
        XCTAssertEqual(facts["long"]?.count, StepTraceLimits.maxValueLength)
        XCTAssertTrue(facts["long"]?.hasSuffix("…") == true)
        let exact = String(repeating: "x", count: StepTraceLimits.maxValueLength)
        XCTAssertEqual(StepTraceBuffer.clipped(exact), exact)
    }

    func testEncodingIsDeterministicAndRoundTrips() throws {
        let entry = StepTraceEntry(stage: "scroll-search-end",
                                   facts: ["zeta": "1", "alpha": "2", "mid": "3", "beta": "4"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]  // ScenarioEvent / RunResultsStore と同じ
        let first = String(decoding: try encoder.encode(entry), as: UTF8.self)
        XCTAssertEqual(first, #"{"facts":{"alpha":"2","beta":"4","mid":"3","zeta":"1"},"stage":"scroll-search-end"}"#)
        XCTAssertEqual(try JSONDecoder().decode(StepTraceEntry.self, from: Data(first.utf8)), entry)
    }

    func testFrameFormat() {
        XCTAssertEqual(StepTraceFormat.frame(FTRect(x: 0, y: 174, width: 402, height: 700)), "0,174 402x700")
        XCTAssertEqual(StepTraceFormat.frame(FTRect(x: 1.5, y: 2, width: 3, height: 4.5)), "1.5,2 3x4.5")
        XCTAssertEqual(StepTraceFormat.frame(nil), "none")
        // ブリッジの申告のまま来る枠: 非有限・Int に収まらない値で落ちない
        XCTAssertEqual(StepTraceFormat.frame(FTRect(x: .infinity, y: -.infinity, width: .nan, height: 4)), "?,? ?x4")
        XCTAssertFalse(StepTraceFormat.number(1e300).isEmpty)  // Int の範囲外でも落ちない
    }

    // MARK: - 運搬(ScenarioEvent → StepResult → 結果 JSON)

    private func stepEvent(status: String, trace: [StepTraceEntry]?) -> ScenarioEvent {
        var event = ScenarioEvent(kind: "step")
        event.index = 4
        event.description = "scrollTo"
        event.status = status
        event.detail = status == "failed" ? "not found" : nil
        event.trace = trace
        return event
    }

    func testTraceSurvivesEventToStepResultAndToRecordedTimelineAndFailedSteps() throws {
        let trace = [StepTraceEntry(stage: "scroll-search-end", facts: ["reason": "content-unmoving"])]
        let event = stepEvent(status: "failed", trace: trace)

        XCTAssertEqual(ScenarioRunner.stepResult(from: event).trace, trace)
        let decoded = try XCTUnwrap(ScenarioEvent.decode(line: event.encodedLine()))
        XCTAssertEqual(decoded.trace, trace)

        var builder = ScenarioRecordBuilder(scenarioID: "Foo.a", variant: nil, platform: "ios",
                                            title: nil, worker: nil, mode: nil)
        builder.consume(decoded)
        builder.consume(stepEvent(status: "passed", trace: nil))
        let record = builder.build(passed: false, timedOut: false, startedAt: Date(), durationMs: 1, packageRoot: nil)
        XCTAssertEqual(record.timeline?.first?.trace, trace)
        XCTAssertNil(record.timeline?.last?.trace)
        XCTAssertEqual(record.failedSteps?.first?.trace, trace)

        // 結果 JSON を経由しても落ちない
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let back = try JSONDecoder().decode(ScenarioRunRecord.self, from: try encoder.encode(record))
        XCTAssertEqual(back.timeline?.first?.trace, trace)
        XCTAssertEqual(back.failedSteps?.first?.trace, trace)
    }

    func testEmptyTraceIsOmittedFromTheRecord() {
        var builder = ScenarioRecordBuilder(scenarioID: "Foo.a", variant: nil, platform: "ios",
                                            title: nil, worker: nil, mode: nil)
        builder.consume(stepEvent(status: "passed", trace: []))
        let record = builder.build(passed: true, timedOut: false, startedAt: Date(), durationMs: 1, packageRoot: nil)
        XCTAssertNil(record.timeline?.first?.trace)
    }

    /// 運搬経路の継ぎ目(型の効かない所)を1本ずつ押さえる: FTRuntime が event に載せ、親の NDJSON 再構築が写す
    func testCarrierSitesWriteTheTraceField() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        func read(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        XCTAssertTrue(try read("Sources/FTDSL/FTRuntime.swift").contains("event.trace = trace.isEmpty ? nil : trace"))
        XCTAssertTrue(try read("Sources/FTDSL/FTRuntime.swift").contains("trace: outcome?.trace ?? [],"))
        XCTAssertTrue(try read("Sources/fleetest/ApiRunCommand.swift").contains("step.trace = result.trace"))
        XCTAssertTrue(try read("Sources/FTCore/ScenarioRunner.swift").contains("trace: event.trace)"))
        // StepOutcome を組む3つの出口が足跡を詰める
        let executor = try read("Sources/FTCore/StepExecutor.swift")
        XCTAssertEqual(executor.components(separatedBy: "trace: traceThisStep.finished(),").count - 1, 3)
    }

    // MARK: - 他モジュールからの記録口

    func testSinkCollectsOnlyInsideCollectingScope() async {
        StepTraceSink.record(.ocrNearMiss, ["outside": "dropped"])   // 束ねていない = 何もしない
        let collected = await StepTraceSink.collecting { () async -> Int in
            StepTraceSink.record(.ocrNearMiss, ["ocr": "read"])
            return 7
        }
        XCTAssertEqual(collected.result, 7)
        XCTAssertEqual(collected.items.map(\.stage), [.ocrNearMiss])
        XCTAssertEqual(collected.items.first?.facts, ["ocr": "read"])
    }
}
