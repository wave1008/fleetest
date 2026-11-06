import XCTest
@testable import FTDSL

/// removeApp() で消した対象アプリの tapAppIcon が「見つからない」だけで終わらず、消したことと入れ直しを言う
final class TapAppIconRemovedNoteTests: XCTestCase {
    func testRemovedAppNamesRemoveAppAndInstallApp() {
        let note = appIconRemovedByScenarioNote(iconName: "FT E2E iOS", appDisplayName: "FT E2E iOS", stoppedCommand: "removeApp")
        XCTAssertTrue(note.contains("removeApp()"), note)
        XCTAssertTrue(note.contains("installApp()"), note)
    }

    func testNothingIsAddedForOtherStopsOrOtherApps() {
        XCTAssertEqual(appIconRemovedByScenarioNote(iconName: "A", appDisplayName: "A", stoppedCommand: "terminateApp"), "")
        XCTAssertEqual(appIconRemovedByScenarioNote(iconName: "A", appDisplayName: "A", stoppedCommand: nil), "")
        XCTAssertEqual(appIconRemovedByScenarioNote(iconName: "Other", appDisplayName: "A", stoppedCommand: "removeApp"), "")
        XCTAssertEqual(appIconRemovedByScenarioNote(iconName: "A", appDisplayName: nil, stoppedCommand: "removeApp"), "")
    }
}
