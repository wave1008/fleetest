// 探索の途中で木の持ち主が基準のアプリから変わった周回があったら、その事実を失敗文と注記に添える(判定は変えない)。

import XCTest
@testable import FTCore

final class ScrollOwnerChangedDuringSearchTests: XCTestCase {

    private let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "missing"), direction: "up", maxSwipes: 8)

    private func rows(_ offset: Double) -> [ElementInfo] {
        [ElementInfo(ref: 1, type: "scrollView", identifier: "list", label: nil, value: nil, placeholder: nil,
                     enabled: true, frame: FTRect(x: 0, y: 100, width: 400, height: 500), depth: 0, scrollable: true),
         ElementInfo(ref: 2, type: "staticText", identifier: "row_a", label: "a", value: nil, placeholder: nil,
                     enabled: true, frame: FTRect(x: 16, y: 120 - offset, width: 368, height: 40), depth: 1),
         ElementInfo(ref: 3, type: "staticText", identifier: "row_b", label: "b", value: nil, placeholder: nil,
                     enabled: true, frame: FTRect(x: 16, y: 200 - offset, width: 368, height: 40), depth: 1)]
    }

    func testFactIsInTheFailureTextAndTheNote() {
        var r = StepExecutor.ScrollSearchResult(found: false, fallback: nil, viaXCUITest: false, hintJumps: 0,
                                                swipes: 3, stoppedUnmoving: true, contentEverMoved: true)
        r.ownerChangedDuringSearch = (bundleID: "com.other", round: 2)
        let m = StepExecutor.scrollNotFoundMessage(step, r, defaultMaxSwipes: 8)
        XCTAssertTrue(m.contains("owner changed to com.other (round 2)"), m)
        XCTAssertTrue(StepExecutor.scrollSearchNote(r)?.contains("com.other") == true)
        r.ownerChangedDuringSearch = nil
        XCTAssertFalse(StepExecutor.scrollNotFoundMessage(step, r, defaultMaxSwipes: 8).contains("owner changed"))
        XCTAssertNil(StepExecutor.scrollSearchNote(r))
    }

    /// 途中の1周だけ別の bundle の木が返り、打ち切りの時点では戻っている形
    func testOneForeignRoundIsReportedEvenThoughTheTreeIsBackAtTheStop() async throws {
        let primary = FakeAppDriver(name: "primary", log: CallLog(),
                                    snapshotElements: [rows(0), rows(0), rows(60), rows(60)])
        primary.appForeground = true
        primary.sessionBundleIDs = ["com.app", "com.app", "com.other", "com.app"]
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        executor.launchedBundleID = "com.app"

        let outcome = await executor.execute(step)

        guard case .failed(let reason) = outcome.status else { XCTFail("見つからないので failed のはず"); return }
        XCTAssertTrue(reason.contains("com.other"), reason)
    }

    /// 持ち主が変わらない探索には何も足さない
    func testNoFactWhenTheOwnerNeverChanged() async throws {
        let primary = FakeAppDriver(name: "primary", log: CallLog(),
                                    snapshotElements: [rows(0), rows(0), rows(60), rows(60)])
        primary.appForeground = true
        primary.sessionBundleIDs = ["com.app"]
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        executor.launchedBundleID = "com.app"

        let outcome = await executor.execute(step)

        guard case .failed(let reason) = outcome.status else { XCTFail("見つからないので failed のはず"); return }
        XCTAssertFalse(reason.contains("owner changed"), reason)
    }
}
