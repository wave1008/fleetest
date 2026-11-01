// launch 前・terminate 後の「セッションが無い」の文(`withRecovery` と `recoverAndRethrow` が共有)。

import XCTest
@testable import FTBridgeClient

final class NoSessionMessageTests: XCTestCase {
    func testNoSessionMessageNamesTheCliAndDoesNotBlameARunnerRestart() {
        let text = SessionRecoveryDriver.noSessionMessage
        XCTAssertTrue(text.contains("fleetest launch"), text)
        XCTAssertFalse(text.contains("restart"), text)
    }
}
