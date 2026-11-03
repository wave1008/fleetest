// `--remote-timeout` の検査(0 以下は黙って 1800 秒に丸められていた・遠隔へ行かない run では効く相手が無い)と、
// dry-run の `--runner` 警告(登録簿に無い名前を事実として言う)。

import XCTest
import ArgumentParser
import FTCore
@testable import fleetest

final class RemoteTimeoutRejectionTests: XCTestCase {
    func testRunRejectsZeroRemoteTimeout() {
        XCTAssertThrowsError(try RunScenarios.parse(["--profile", "ios", "--remote-timeout", "0"])) { error in
            XCTAssertTrue(RunScenarios.message(for: error).contains("--remote-timeout must be a positive"))
        }
    }

    func testRunRejectsRemoteTimeoutWithoutProfile() {
        XCTAssertThrowsError(try RunScenarios.parse(["--remote-timeout", "60"])) { error in
            XCTAssertTrue(RunScenarios.message(for: error).contains("--remote-timeout requires --profile"))
        }
    }

    func testRunAllowsPositiveRemoteTimeoutWithProfile() {
        XCTAssertNoThrow(try RunScenarios.parse(["--profile", "ios", "--remote-timeout", "60"]))
    }

    func testDryRunRunnerWarningNamesUnregisteredRunner() {
        let entries = [RemoteHostEntry(machine: "m1", host: "u@h")]
        XCTAssertTrue(dryRunRunnerWarning(runner: "nosuch", entries: entries)?.contains("not a registered machine") == true)
        XCTAssertNil(dryRunRunnerWarning(runner: "m1", entries: entries))
        XCTAssertNil(dryRunRunnerWarning(runner: "local", entries: entries))
    }
}
