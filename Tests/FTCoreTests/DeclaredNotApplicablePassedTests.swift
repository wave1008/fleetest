// OI-118: 宣言による対象外の合成レコードは、実行時の対象外(子が宣言した形)と同じ `passed: true`。noWorker は false のまま。

import XCTest
@testable import FTCore

final class DeclaredNotApplicablePassedTests: XCTestCase {
    func testDeclaredNotApplicableIsPassedAndNoWorkerIsNot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ft-na-passed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = RunRecorder.begin(project: TestProject(name: "P", rootURL: root), profile: "ios", trigger: "test",
                                         captureHostMetrics: false, lastResultsDir: nil)
        recorder.recordSkipped(scenarioID: "C.three", title: nil, platform: "android", worker: nil,
                               reason: "not applicable", kind: .notApplicable)
        recorder.recordSkipped(scenarioID: "A.one", title: nil, platform: "ios", worker: nil, reason: "no worker")
        var passedByID: [String: Bool] = [:]
        let dir = recorder.runDir.appendingPathComponent("scenarios")
        for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            let record = try JSONDecoder().decode(ScenarioRunRecord.self, from: Data(contentsOf: file))
            passedByID[record.scenarioID] = record.passed
        }
        XCTAssertEqual(passedByID["C.three"], true)
        XCTAssertEqual(passedByID["A.one"], false)
    }
}
