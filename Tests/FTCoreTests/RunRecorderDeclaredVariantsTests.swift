// run.json の `variants`(宣言の名前)は begin・計測の書き直し・finish のどれでも消えない
// (RunMetaRecord の init が `variants: = nil` の既定を持つので、渡し忘れはコンパイルで止まらない)。

import XCTest
@testable import FTCore

final class RunRecorderDeclaredVariantsTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-variants-recorder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeRecorder(_ variants: [String]) -> RunRecorder {
        RunRecorder.begin(project: TestProject(name: "P", rootURL: root), profile: "android", trigger: "test",
                          captureHostMetrics: false, declaredVariants: variants)
    }

    private func finish(_ recorder: RunRecorder) {
        recorder.finish(total: 1, passed: 1, failed: 0, performanceMode: false,
                        effectiveSettings: EffectiveSettingsRecord(heal: false, fmTextVisibilityCheck: false,
                                                      screenLooksLike: false, ocrTextVisibilityCheck: false),
                        setOverrides: nil, servicesWarnings: [], responseMeasurement: nil)
    }

    func testDeclaredVariantsSurviveMeasurementRewriteAndFinish() {
        let recorder = makeRecorder(["default", "dark"])
        XCTAssertEqual(RunResultsStore.meta(runDir: recorder.runDir)?.variants, ["default", "dark"])
        recorder.recordResponseMeasurement(ResponseMeasurementRunInfo(deviceName: "D", serial: "S", model: "M",
                                                                      osVersion: "13", repeatCount: 1))
        XCTAssertEqual(RunResultsStore.meta(runDir: recorder.runDir)?.variants, ["default", "dark"])
        finish(recorder)
        let meta = RunResultsStore.meta(runDir: recorder.runDir)
        XCTAssertNotNil(meta?.finishedAt)
        XCTAssertEqual(meta?.variants, ["default", "dark"])
    }

    func testRunWithoutVariantsOmitsTheKey() throws {
        let recorder = makeRecorder([])
        finish(recorder)
        let data = try Data(contentsOf: recorder.runDir.appendingPathComponent("run.json"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"variants\""))
    }
}
