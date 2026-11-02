// 実行プロファイルの `orientation`(各シナリオの最初の launch の直後に rotateTo)

import XCTest
@testable import FTCore

final class RunProfileOrientationTests: XCTestCase {
    /// 既定は「指定なし = 向きに触らない」(リテラルで固定。他のテストが差し替えても production の既定を通る)
    func testDefaultIsUnset() {
        XCTAssertNil(ScenarioExecutionSettings().orientation)
        XCTAssertNil(DeviceIndependentRunSettings.resolve(RunProfileDocument()).orientation)
        XCTAssertNil(DeviceIndependentRunSettings.resolve(DeviceIndependentRunSettings.profileLessBase).orientation)
    }

    func testSetOverrideReachesTheSettings() throws {
        let overrides = try RunProfileSetOverride.parse(["orientation=landscape"])
        let doc = RunProfileDocument().applyingOverrides(overrides)
        let resolved = DeviceIndependentRunSettings.resolve(doc)
        XCTAssertEqual(resolved.orientation, .landscape)
        XCTAssertEqual(ScenarioExecutionSettings(resolved).orientation, .landscape)
    }

    func testRejectsAnUnknownOrientation() {
        XCTAssertThrowsError(try RunProfileSetOverride.parse(["orientation=sideways"])) {
            XCTAssertTrue($0.localizedDescription.contains("portrait/landscape"), "\($0)")
        }
    }

    func testStaticValidationRejectsAnUnknownOrientation() {
        let json = #"{"app":"a","devices":[{"platform":"ios","name":"d"}],"orientation":"sideways"}"#
        let errors = ProfileResolver.validate(kind: .run, data: Data(json.utf8), context: "x").errors
        XCTAssertTrue(errors.contains { $0.contains("orientation") }, "\(errors)")
    }

    /// 子へ運ぶ配線(型の効かない継ぎ目): ScenarioHost が `--orientation` を渡し、子が受ける
    func testHostPassesTheFlagAndTheRunnerAcceptsIt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let host = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/ScenarioHost.swift"), encoding: .utf8)
        let runner = try String(contentsOf: root.appendingPathComponent("Sources/FTScenarioRunner/ScenarioRunnerMain.swift"),
                                encoding: .utf8)
        XCTAssertTrue(host.contains(#"["--orientation", orientation.rawValue]"#))
        XCTAssertTrue(runner.contains(#"customLong("orientation")"#))
    }
}
