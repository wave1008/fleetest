import XCTest
@testable import fleetest

/// 控えにあるコンテナがランタイムから消された形(`container delete`)も「動いていない」警告に入れる。
/// 一覧が読めたときだけ「無い」と言い、読めなければ(nil)入れない。
final class ServicesMissingContainerTests: XCTestCase {
    func testNameAbsentFromReadableListingIsMissing() {
        XCTAssertTrue(ServicesCommand.isMissing("ws-side", listed: ["ws-web"]))
    }

    func testNameInListingIsNotMissing() {
        XCTAssertFalse(ServicesCommand.isMissing("ws-web", listed: ["ws-web"]))
    }

    func testUnreadableListingNeverSaysMissing() {
        XCTAssertFalse(ServicesCommand.isMissing("ws-side", listed: nil))
    }
}
