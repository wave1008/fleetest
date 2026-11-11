// Vision の死活台帳(VisionLiveness)・変わり目の履歴・確かめ(VisionLivenessProbe)。
// 台帳は一時フォルダへ書く(本番の ~/.fleetest には触れない)。

import XCTest
@testable import FTCore

final class VisionLivenessTests: XCTestCase {
    func testConstantsArePinned() {
        XCTAssertEqual(VisionLiveness.probeIntervalSeconds, 60)
        XCTAssertEqual(VisionLiveness.freshSeconds, 120)
        XCTAssertEqual(VisionLiveness.errorLimit, 200)
        XCTAssertEqual(VisionLivenessProbe.deadlineSeconds, 120, "OCR の初回のコンパイル(実測最大 108 秒)を死と読まない")
        XCTAssertEqual(VisionLivenessHistory.maxBytes, 5_242_880)
    }

    private func tempLedger() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fleetest-vision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent(VisionLiveness.fileName)
    }

    func testUnknownWhenMissingOrStaleAndSubjectsAreIndependent() throws {
        let url = try tempLedger()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(VisionLiveness.current(.ocr, at: url, now: now))
        VisionLiveness.write(.ocr, .init(state: .dead, checkedAt: now.timeIntervalSince1970 - 121, source: .probe, error: "x"), to: url)
        XCTAssertNil(VisionLiveness.current(.ocr, at: url, now: now), "120 秒より古い観測は不明のはず")
        VisionLiveness.write(.ocr, .init(state: .dead, checkedAt: now.timeIntervalSince1970 - 10, source: .probe, error: "x"), to: url)
        VisionLiveness.write(.featurePrint, .init(state: .alive, checkedAt: now.timeIntervalSince1970 - 10, source: .probe), to: url)
        XCTAssertEqual(VisionLiveness.current(.ocr, at: url, now: now)?.state, .dead)
        XCTAssertEqual(VisionLiveness.current(.featurePrint, at: url, now: now)?.state, .alive)
    }

    func testOlderObservationDoesNotOverwritePerSubject() throws {
        let url = try tempLedger()
        VisionLiveness.write(.ocr, .init(state: .dead, checkedAt: 200, source: .probe, error: "broken"), to: url)
        VisionLiveness.write(.ocr, .init(state: .alive, checkedAt: 100, source: .probe), to: url)
        XCTAssertEqual(VisionLiveness.read(.ocr, at: url)?.state, .dead)
        // 別の対象の古い時刻は、その対象に記録が無ければ書ける
        VisionLiveness.write(.featurePrint, .init(state: .alive, checkedAt: 100, source: .probe), to: url)
        XCTAssertEqual(VisionLiveness.read(.featurePrint, at: url)?.state, .alive)
        VisionLiveness.write(.ocr, .init(state: .alive, checkedAt: 300, source: .probe), to: url)
        XCTAssertEqual(VisionLiveness.read(.ocr, at: url)?.state, .alive)
    }

    func testErrorIsDroppedWhenAliveAndTruncatedWhenDead() throws {
        let url = try tempLedger()
        XCTAssertNil(VisionLiveness.Verdict(state: .alive, checkedAt: 1, source: .probe, error: "stale").error)
        VisionLiveness.write(.ocr, .init(state: .dead, checkedAt: 1, source: .probe, error: String(repeating: "e", count: 500)), to: url)
        XCTAssertEqual(VisionLiveness.read(.ocr, at: url)?.error?.count, VisionLiveness.errorLimit)
    }

    func testWriteReturnsThePreviousStateOfThatSubject() throws {
        let url = try tempLedger()
        XCTAssertEqual(VisionLiveness.write(.ocr, .init(state: .alive, checkedAt: 100, source: .probe), to: url), .some(nil))
        XCTAssertEqual(VisionLiveness.write(.featurePrint, .init(state: .dead, checkedAt: 150, source: .probe, error: "x"), to: url),
                       .some(nil), "別の対象の記録は前の状態に数えない")
        XCTAssertEqual(VisionLiveness.write(.ocr, .init(state: .dead, checkedAt: 200, source: .probe, error: "x"), to: url),
                       .some(.alive))
        XCTAssertNil(VisionLiveness.write(.ocr, .init(state: .alive, checkedAt: 150, source: .probe), to: url))
    }

    /// 変わり目だけを履歴へ書く(env の置き場で本物の record の経路を通す)
    func testRecordWritesOnlyTransitionsToHistory() throws {
        let dir = try tempLedger().deletingLastPathComponent()
        setenv(VisionLiveness.directoryOverrideKey, dir.path, 1)
        defer { unsetenv(VisionLiveness.directoryOverrideKey) }
        VisionLiveness.record(.ocr, .init(state: .alive, checkedAt: 1, source: .probe))
        VisionLiveness.record(.ocr, .init(state: .dead, checkedAt: 2, source: .probe, error: "empty"))
        VisionLiveness.record(.ocr, .init(state: .dead, checkedAt: 3, source: .probe, error: "empty"))
        VisionLiveness.record(.featurePrint, .init(state: .dead, checkedAt: 3, source: .probe, error: "degenerate"))
        VisionLiveness.record(.ocr, .init(state: .alive, checkedAt: 4, source: .probe))
        let lines = VisionLivenessHistory.read(at: dir.appendingPathComponent(VisionLivenessHistory.fileName))
        XCTAssertEqual(lines.map { "\($0.subject.rawValue):\($0.event.rawValue)" },
                       ["ocr:becameDead", "featurePrint:becameDead", "ocr:becameAlive"])
        XCTAssertEqual(lines.first?.detail, "empty")
    }

    func testInjectionPerSubject() {
        XCTAssertTrue(VisionLivenessProbe.isInjectedDead(.ocr, environment: ["FT_FAKE_VISION_DEAD": "ocr"]))
        XCTAssertFalse(VisionLivenessProbe.isInjectedDead(.featurePrint, environment: ["FT_FAKE_VISION_DEAD": "ocr"]))
        XCTAssertTrue(VisionLivenessProbe.isInjectedDead(.featurePrint, environment: ["FT_FAKE_VISION_DEAD": "featurePrint"]))
        XCTAssertTrue(VisionLivenessProbe.isInjectedDead(.ocr, environment: ["FT_FAKE_VISION_DEAD": "all"]))
        XCTAssertTrue(VisionLivenessProbe.isInjectedDead(.featurePrint, environment: ["FT_FAKE_VISION_DEAD": "all"]))
        XCTAssertFalse(VisionLivenessProbe.isInjectedDead(.ocr, environment: [:]))
        XCTAssertFalse(VisionLivenessProbe.isInjectedDead(.ocr, environment: ["FT_FAKE_VISION_DEAD": "1"]))
    }

    /// 注入は Vision に触らずに死を返す(OCR 非対応・コンパイル中でも注入が先)
    func testInjectedProbeReturnsDeadWithoutTouchingVision() async {
        let ocr = await VisionLivenessProbe.check(.ocr, environment: ["FT_FAKE_VISION_DEAD": "ocr"], ocrSupported: false,
                                                  compileActiveCount: { XCTFail("注入では台帳を見ない"); return 0 })
        XCTAssertEqual(ocr?.state, .dead)
        XCTAssertTrue(ocr?.error?.contains("injected") ?? false)
        let fp = await VisionLivenessProbe.check(.featurePrint, environment: ["FT_FAKE_VISION_DEAD": "ocr"])
        XCTAssertNotEqual(fp?.state, .dead, "ocr だけの注入で特徴量は死なない(実際に確かめて生 or nil)")
        let fpDead = await VisionLivenessProbe.check(.featurePrint, environment: ["FT_FAKE_VISION_DEAD": "all"])
        XCTAssertEqual(fpDead?.state, .dead)
    }

    func testProbeSkipsWhenUnsupportedOrCompiling() async {
        let unsupported = await VisionLivenessProbe.check(.ocr, environment: [:], ocrSupported: false, compileActiveCount: { 0 })
        XCTAssertNil(unsupported)
        let compilingOCR = await VisionLivenessProbe.check(.ocr, environment: [:], ocrSupported: true, compileActiveCount: { 1 })
        XCTAssertNil(compilingOCR)
        let compilingFP = await VisionLivenessProbe.check(.featurePrint, environment: [:], ocrSupported: true, compileActiveCount: { 1 })
        XCTAssertNil(compilingFP)
    }

    /// OCR 非対応でも特徴量は撃つ(非対応は ocr だけの扱い)。実 Vision を1回通し、使用台帳へ書かないことも確かめる
    func testFeaturePrintProbeIsAliveAndDoesNotCountUsage() async {
        let before = FindImage.featurePrintCount
        let verdict = await VisionLivenessProbe.check(.featurePrint, environment: [:], ocrSupported: false, compileActiveCount: { 0 })
        XCTAssertEqual(verdict?.state, .alive, verdict?.error ?? "")
        XCTAssertEqual(FindImage.featurePrintCount, before, "確かめは特徴量の計数(= 使用台帳に並ぶ回数)を増やさない")
    }

    func testDistinctImageIsBuildable() {
        XCTAssertNotNil(VisionLivenessProbe.distinctImage())
    }

    /// NDJSON の6欄は不明でも必ず出す(拡張は欠けた行を捨てる)
    func testHostMetricsSampleAlwaysCarriesVisionKeys() throws {
        let unknown = try XCTUnwrap(HostMetricsSample(
            ts: 1, cpu: nil, gpu: nil, memUsedBytes: nil, memTotalBytes: nil, fmCalls: nil, fmFailures: nil,
            fmTotalMs: nil, visionCalls: nil, visionFailures: nil, visionTotalMs: nil, ocrCompiling: 0).encodedLine())
        for key in ["visionOCRState", "visionOCRError", "visionOCRCheckedAt",
                    "visionFeaturePrintState", "visionFeaturePrintError", "visionFeaturePrintCheckedAt"] {
            XCTAssertTrue(unknown.contains("\"\(key)\":null"), "\(key): \(unknown)")
        }
        let dead = try XCTUnwrap(HostMetricsSample(
            ts: 1, cpu: nil, gpu: nil, memUsedBytes: nil, memTotalBytes: nil, fmCalls: nil, fmFailures: nil,
            fmTotalMs: nil, visionCalls: nil, visionFailures: nil, visionTotalMs: nil, ocrCompiling: 0,
            visionOCR: .init(state: .dead, checkedAt: 5, source: .probe, error: "empty"),
            visionFeaturePrint: .init(state: .alive, checkedAt: 6, source: .probe)).encodedLine())
        XCTAssertTrue(dead.contains(#""visionOCRState":"dead""#), dead)
        XCTAssertTrue(dead.contains(#""visionOCRError":"empty""#), dead)
        XCTAssertTrue(dead.contains(#""visionOCRCheckedAt":5"#), dead)
        XCTAssertTrue(dead.contains(#""visionFeaturePrintState":"alive""#), dead)
        XCTAssertTrue(dead.contains(#""visionFeaturePrintError":null"#), dead)
    }
}
