// `--align` / `--tool-rev` の適用範囲(単一のリモートだけ)の断り。引数だけで決まる分は validate() の
// 共通関数(RunCommonOptions.validateToolSync)・実行プロファイルを読んで分かる分(機械分担・全台が手元・dry-run)は
// 各 run() の分岐から呼ぶ `rejectToolSyncOutsideSingleRemote`。**文言は1つ**。

import XCTest
import ArgumentParser
@testable import fleetest

final class RunToolSyncScopeTests: XCTestCase {
    private func parse(_ arguments: [String]) throws -> RunScenarios {
        try RunScenarios.parse(arguments)
    }

    func testRejectMessageNamesTheGivenFlagsAndTheScope() throws {
        let both = try parse(["--profile", "p", "--runner", "m1", "--align", "--tool-rev", "HEAD"])
        XCTAssertThrowsError(try both.common.rejectToolSyncOutsideSingleRemote()) { error in
            let message = (error as? ValidationError)?.message ?? "\(error)"
            XCTAssertTrue(message.hasPrefix("--align / --tool-rev applies only to a dispatch to one remote runner"), message)
        }
        let neither = try parse(["--profile", "p"])
        XCTAssertNoThrow(try neither.common.rejectToolSyncOutsideSingleRemote())
    }

    func testFleetAndMultiTargetAreRejectedBeforeAnythingRuns() {
        XCTAssertThrowsError(try RunScenarios.parse(["--fleet", "f", "--align"]))
        XCTAssertThrowsError(try RunScenarios.parse(["--target", "P:a", "--target", "P:b", "--tool-rev", "HEAD"]))
        XCTAssertThrowsError(try RunScenarios.parse(["--profile", "a", "--profile", "b", "--align"]))
    }

    func testSingleRemoteRunnerIsAccepted() {
        XCTAssertNoThrow(try RunScenarios.parse(["--profile", "p", "--runner", "m1", "--align"]))
        XCTAssertNoThrow(try RunScenarios.parse(["--profile", "p", "--runner", "m1", "--tool-rev", "HEAD"]))
    }
}
