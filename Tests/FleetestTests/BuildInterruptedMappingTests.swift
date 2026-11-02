// 中断で止めたビルド(`ScenarioHostError.buildInterrupted`)は、ビルドの失敗でなく開始前の中断として扱う。

import XCTest
import FTCore
@testable import fleetest

final class BuildInterruptedMappingTests: XCTestCase {
    /// 破ると落ちる: 写像を外す(そのまま返す)と buildInterrupted が中断にならない
    func testBuildInterruptedBecomesAnInterruptionBeforeStart() {
        let mapped = RunInterruptedBeforeStartError.mappingBuildError(ScenarioHostError.buildInterrupted)
        XCTAssertTrue(mapped is RunInterruptedBeforeStartError)
    }

    /// 破ると落ちる: 常に中断へ写すと本物のビルド失敗が JUnit にも run.json にも失敗として残らない
    func testARealBuildFailureStaysABuildFailure() {
        let mapped = RunInterruptedBeforeStartError.mappingBuildError(ScenarioHostError.buildFailed("x"))
        XCTAssertFalse(mapped is RunInterruptedBeforeStartError)
        guard case ScenarioHostError.buildFailed = mapped else { return XCTFail("別のエラーに化けた") }
    }

    /// run / api run のビルド呼び出しが写像を通る(配線は型で守れない)
    func testBothRunPathsMapTheBuildError() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Sources/fleetest/Fleetest.swift", "Sources/fleetest/ApiRunCommand.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(text.contains("RunInterruptedBeforeStartError.mappingBuildError("), path)
        }
    }
}
