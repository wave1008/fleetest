// setAppearance / setTextSize(CommandsDisplay.swift)のフックの中での断りと、使えない名前の受け皿。
import XCTest
@testable import FTDSL

final class DisplaySettingCommandTests: XCTestCase {

    func testRefusedInEveryRunAndDeviceHook() {
        for section in ["beforeAll", "setUpDevice", "tearDownDevice", "afterAll", "beforeRun", "afterRun"] {
            for command in ["setAppearance", "setTextSize"] {
                let reason = FTDriveCore.displaySettingRejection(command: command, section: section)
                XCTAssertNotNil(reason, "\(command) in \(section)")
                XCTAssertTrue(reason?.contains(command) == true && reason?.contains(section) == true, reason ?? "")
                XCTAssertTrue(reason?.contains("run profile") == true, "全体に効かせる代わりを案内する: \(reason ?? "")")
            }
        }
    }

    func testAllowedInTestBodyAndEachHooks() {
        for section in [nil, "beforeEach", "afterEach", "test"] as [String?] {
            XCTAssertNil(FTDriveCore.displaySettingRejection(command: "setAppearance", section: section), section ?? "nil")
        }
    }
}
