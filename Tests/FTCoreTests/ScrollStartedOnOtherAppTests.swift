// 始点の木が起こしたアプリでなく別のアプリのもの(設定が前面)だった探索の扱い・整定を打ち切った探索の待ちの案内(OI-169 ④)。

import XCTest
@testable import FTCore

final class ScrollStartedOnOtherAppTests: XCTestCase {

    private var step: FlowStep { FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_40"), direction: "up") }

    func testStartOwnerOtherThanLaunched() {
        XCTAssertEqual(StepExecutor.startOwnerOtherThanLaunched(treeSession: "com.android.settings", launched: "com.example"),
                       "com.android.settings")
        XCTAssertNil(StepExecutor.startOwnerOtherThanLaunched(treeSession: "com.example", launched: "com.example"))
        XCTAssertNil(StepExecutor.startOwnerOtherThanLaunched(treeSession: "com.android.settings", launched: nil), "起こしていない = 意図した別の面")
        XCTAssertNil(StepExecutor.startOwnerOtherThanLaunched(treeSession: nil, launched: "com.example"))
        let dialog = ForegroundState.systemDialogPackages.first!
        XCTAssertNil(StepExecutor.startOwnerOtherThanLaunched(treeSession: dialog, launched: "com.example"), "システムのダイアログは割り込み")
    }

    /// 失敗文は始点から別アプリだった事実を言い、途中で替わったとは言わない(陽性対照: 途中で替わった形は従来の文)
    func testFailureMessageStatesTheStartAsAFactNotAMidSearchChange() {
        var r = StepExecutor.ScrollSearchResult(found: false, fallback: nil, viaXCUITest: false, hintJumps: 0, swipes: 2)
        r.startedOnOtherApp = ("com.android.settings", "com.example")
        let m = StepExecutor.scrollNotFoundMessage(step, r, defaultMaxSwipes: 8)
        XCTAssertTrue(m.contains("started with the screen owned by com.android.settings, not the app launched (com.example)"), m)
        XCTAssertFalse(m.contains("owner changed"), m)
        var changed = StepExecutor.ScrollSearchResult(found: false, fallback: nil, viaXCUITest: false, hintJumps: 0, swipes: 2)
        changed.ownerChangedDuringSearch = ("com.android.settings", 1)
        XCTAssertTrue(StepExecutor.scrollNotFoundMessage(step, changed, defaultMaxSwipes: 8).contains("owner changed"))
    }

    /// 逆走査の2経路が始点の別アプリで閉じ、「途中で替わった」の比較が始点の持ち主を除いている(配線の走査)
    func testSearchWiring() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FTCore/StepExecutor+ScrollSearch.swift").path
        let source = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(source.contains("guard startedOnOther == nil, contentEverMoved"))
        XCTAssertTrue(source.contains("if startedOnOther == nil, movedByEvidence"))
        XCTAssertTrue(source.contains("owner != base, owner != startedOnOther"))
    }

    /// 整定を打ち切った探索の見失いは waitSeconds: を案内しない。打ち切っていなければ従来の案内
    func testWaitHintAfterSearch() {
        XCTAssertFalse(StepExecutor.waitHintAfterSearch(step, settleCutOff: true).contains("waitSeconds: to this step"))
        XCTAssertTrue(StepExecutor.waitHintAfterSearch(step, settleCutOff: true).contains("settle wait ran out"))
        XCTAssertTrue(StepExecutor.waitHintAfterSearch(step, settleCutOff: false).contains("add waitSeconds: to this step"))
        var noScroll = step
        noScroll.direction = nil
        XCTAssertTrue(StepExecutor.waitHintAfterSearch(noScroll, settleCutOff: true).contains("add waitSeconds: to this step"),
                      "探索を撃っていない手順は従来")
    }
}
