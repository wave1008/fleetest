// `remote exec` の入れ子ディスパッチ防止は `--runner X` と `--runner=X` の両方に効く。

import XCTest
@testable import fleetest

final class RemoteExecNestedRunnerTests: XCTestCase {
    func testRejectsBothSpellingsOfRunner() {
        XCTAssertTrue(RemoteCommand.Exec.relaysRunnerFlag(["run", "--runner", "m2"]))
        XCTAssertTrue(RemoteCommand.Exec.relaysRunnerFlag(["run", "--runner=m2"]))
    }

    func testAllowsUnrelatedArguments() {
        XCTAssertFalse(RemoteCommand.Exec.relaysRunnerFlag(["doctor", "--fm-only"]))
        XCTAssertFalse(RemoteCommand.Exec.relaysRunnerFlag(["run", "--runner-note=x"]))
    }
}
