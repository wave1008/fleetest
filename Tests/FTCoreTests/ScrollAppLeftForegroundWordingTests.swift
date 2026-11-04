// 探索の途中で前面を奪われたとき、木が変わらないのを「端に着いた」と言い切らない。

import XCTest
@testable import FTCore

final class ScrollAppLeftForegroundWordingTests: XCTestCase {

    private let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "missing"), direction: "up", maxSwipes: 8)

    func testLeftForegroundDoesNotClaimTheEnd() {
        var r = StepExecutor.ScrollSearchResult(found: false, fallback: nil, viaXCUITest: false,
                                                hintJumps: 0, swipes: 3)
        r.appLeftForeground = "com.apple.Preferences"
        let m = StepExecutor.scrollNotFoundMessage(step, r, defaultMaxSwipes: 8)
        XCTAssertTrue(m.contains("com.apple.Preferences was in front"), m)
        XCTAssertTrue(m.contains("after 3 scroll(s)"), m)
        XCTAssertFalse(m.contains("reached its end"), m)
    }

    /// 探索の前にアプリが落ちて始点の木がランチャーなら、起こしたアプリを基準にする。起こしていなければ木のまま
    func testSearchBaselineIsTheLaunchedAppWhenTheTreeStartedElsewhere() {
        XCTAssertEqual(StepExecutor.searchBaselineBundleID(treeSession: "com.android.launcher", launched: "com.example"), "com.example")
        XCTAssertEqual(StepExecutor.searchBaselineBundleID(treeSession: "com.example", launched: "com.example"), "com.example")
        XCTAssertEqual(StepExecutor.searchBaselineBundleID(treeSession: "com.android.launcher", launched: nil), "com.android.launcher")
        XCTAssertNil(StepExecutor.searchBaselineBundleID(treeSession: nil, launched: "com.example"))
    }

    /// 探索の基準の取り方が配線されている(木の名前を直に入れる形へ戻すと落ちる)
    func testScrollSearchUsesTheBaseline() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FTCore/StepExecutor+ScrollSearch.swift").path
        let source = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(source.contains("searchBundleID = Self.searchBaselineBundleID("))
        XCTAssertFalse(source.contains("searchBundleID = snapshot.sessionBundleID"))
    }

    func testFailFastMessageNamesTheFrontWhenTheAppLeft() {
        var scrollFrameStep = step
        scrollFrameStep.scrollFrame = FlowLocator(id: "list")
        var r = StepExecutor.ScrollSearchResult(found: false, fallback: nil, viaXCUITest: false,
                                                hintJumps: 0, swipes: 2, scrollFrameMissing: true)
        r.appLeftForeground = "com.android.systemui"
        let m = StepExecutor.scrollNotFoundMessage(scrollFrameStep, r, defaultMaxSwipes: 8)
        XCTAssertTrue(m.contains("disappeared from the tree"), m)
        XCTAssertTrue(m.contains("com.android.systemui was in front"), m)
    }
}
