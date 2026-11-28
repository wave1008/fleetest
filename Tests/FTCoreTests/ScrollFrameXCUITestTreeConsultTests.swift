// inapp-boost で明示 scrollFrame が in-app の木で解けないとき、払わずに赤にする前にアプリの XCUITest の木を1回照会し、
// 解けて XCUITest が押せると答えた容器の枠で払う(DR-241)。実測の形: `TabView(.page)` は XCUITest で `collectionView`・
// in-app で `other` なので、MCP の木で書いた `.collectionView#pager_main` が本番だけ「matched nothing」になった
import XCTest
@testable import FTCore

final class ScrollFrameXCUITestTreeConsultTests: XCTestCase {

    private static let pagerFrame = FTRect(x: 0, y: 200, width: 390, height: 300)
    private static let inAppPager = ElementInfo(ref: 1, type: "other", identifier: "pager_main", label: nil, value: nil,
                                                placeholder: nil, enabled: true, frame: pagerFrame, depth: 1)
    private static let xcuitestPager = ElementInfo(ref: 7, type: "collectionView", identifier: "pager_main", label: nil, value: nil,
                                                   placeholder: nil, enabled: true, frame: pagerFrame, depth: 1)

    private func flick(hittable: HitTestAnswer = .hittable(true), xcuitestTree: [ElementInfo] = [xcuitestPager],
                       withTypeDriver: Bool = true) async -> (StepOutcome, FakeAppDriver, CallLog) {
        let log = CallLog()
        let inApp = FakeAppDriver(name: "primary", log: log, snapshotElements: [[Self.inAppPager]])
        let xcuitest = FakeAppDriver(name: "xcuitest", log: log, snapshotElements: [xcuitestTree])
        xcuitest.appForeground = true
        xcuitest.hitTestAnswer = hittable
        let executor = StepExecutor(driver: inApp, typeDriver: withTypeDriver ? xcuitest : nil, isAndroid: false,
                                    tunables: RunTunables())
        executor.launchedBundleID = "com.example.pager"
        var step = FlowStep(action: "flick", direction: "rightToLeft", maxSwipes: 1)
        step.scrollFrame = FlowLocator(id: "pager_main", type: "collectionView")
        return (await executor.execute(step), inApp, log)
    }

    func testFlickUsesTheFrameFromTheXCUITestTree() async {
        let (outcome, inApp, log) = await flick()
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status) / \(log.entries)") }
        XCTAssertTrue(outcome.notes.contains(.scrollFrameResolvedViaXCUITestTree), "\(outcome.notes)")
        let moves = inApp.dragCalls
        XCTAssertFalse(moves.isEmpty && !log.entries.contains { $0.contains(".swipe") }, "払っていない: \(log.entries)")
        if let first = moves.first {
            XCTAssertTrue(Self.pagerFrame.contains(FTRect(x: first.0, y: first.1, width: 0, height: 0)),
                          "XCUITest の木の枠の中から払っていない: \(first)")
        }
    }

    /// XCUITest が押せないと答えた容器(モーダルの裏)は採らない = 今までどおり払わずに赤
    func testNotHittableContainerStaysRed() async {
        let (outcome, inApp, log) = await flick(hittable: .hittable(false))
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(message.contains("the flick was not sent"), message)
        XCTAssertTrue(inApp.dragCalls.isEmpty && !log.entries.contains { $0.contains(".swipe") }, "\(log.entries)")
        XCTAssertFalse(outcome.notes.contains(.scrollFrameResolvedViaXCUITestTree))
        XCTAssertFalse(outcome.notes.contains(.xcuitestTreeNoMatch), "一致はしている(押せないだけ)= no-match と記録しない: \(outcome.notes)")
    }

    func testAbsentFromBothTreesStaysRed() async {
        let (outcome, _, _) = await flick(xcuitestTree: [])
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(message.contains("the flick was not sent"), message)
        XCTAssertTrue(outcome.notes.contains(.xcuitestTreeNoMatch), "\(outcome.notes)")
    }

    /// scroll・scrollToEdge・scrollTo の探索も同じ照会を通す(払う前の1回)。払えたら「matched nothing」で止まらない
    private func run(_ step: FlowStep, xcuitestTrees: [[ElementInfo]] = [[xcuitestPager]],
                     inAppTree: [ElementInfo] = [inAppPager]) async -> (StepOutcome, FakeAppDriver, CallLog) {
        let log = CallLog()
        let inApp = FakeAppDriver(name: "primary", log: log, snapshotElements: [inAppTree])
        let xcuitest = FakeAppDriver(name: "xcuitest", log: log, snapshotElements: xcuitestTrees)
        xcuitest.appForeground = true
        xcuitest.hitTestAnswer = .hittable(true)
        let executor = StepExecutor(driver: inApp, typeDriver: xcuitest, isAndroid: false, tunables: RunTunables())
        executor.launchedBundleID = "com.example.pager"
        var step = step
        step.scrollFrame = FlowLocator(id: "pager_main", type: "collectionView")
        return (await executor.execute(step), inApp, log)
    }

    func testScrollScrollToEdgeAndSearchAlsoConsult() async {
        let steps = [FlowStep(action: "scroll", direction: "up", maxSwipes: 1),
                     FlowStep(action: "scrollToEdge", direction: "up", maxSwipes: 1),
                     FlowStep(action: "scrollTo", locator: FlowLocator(id: "missing"), maxSwipes: 1)]
        for step in steps {
            let (outcome, inApp, log) = await run(step)
            let action = step.action ?? "?"
            XCTAssertTrue(outcome.notes.contains(.scrollFrameResolvedViaXCUITestTree), "\(action): \(outcome.notes)")
            XCTAssertFalse(outcome.notes.contains(.scrollFrameMissing), "\(action): \(outcome.notes)")
            XCTAssertTrue(!inApp.dragCalls.isEmpty || log.entries.contains { $0.contains(".swipe") }, "\(action) が払っていない: \(log.entries)")
        }
    }

    /// 払った後に XCUITest の木からも容器が消えた(シート・モーダルが置き換えた)なら、古い枠を払い続けずに止める。
    /// 失敗文は元のセレクタを名指す
    func testContainerGoneAfterASwipeStopsTheSwipes() async {
        let steps = [FlowStep(action: "scroll", direction: "up", maxSwipes: 3),
                     FlowStep(action: "scrollToEdge", direction: "up", maxSwipes: 3),
                     FlowStep(action: "scrollTo", locator: FlowLocator(id: "missing"), maxSwipes: 3)]
        for step in steps {
            let (outcome, inApp, log) = await run(step, xcuitestTrees: [[Self.xcuitestPager], []])
            let action = step.action ?? "?"
            guard case .failed(let message) = outcome.status else { XCTFail("\(action) が止まらなかった: \(outcome.status)"); continue }
            XCTAssertTrue(message.contains("pager_main"), "\(action): \(message)")
            XCTAssertTrue(outcome.notes.contains(.scrollFrameMissing), "\(action): \(outcome.notes)")
            let sent = inApp.dragCalls.count + log.entries.filter { $0.contains(".swipe") }.count
            XCTAssertEqual(sent, 1, "\(action): 消えた後も払った: \(log.entries)")
        }
    }

    /// scrollToEdge は比べる範囲を作る前に解く = 動かない画面で「動かなかった」と言える(1周目だけ別の範囲で比べると「動いた」に数える)
    func testScrollToEdgeOnAStillScreenSaysNothingMoved() async {
        // ページャの外の見出し = 画面全体で比べた回と枠の中で比べた回で署名が変わる(範囲が割れると「動いた」に化ける)
        let title = ElementInfo(ref: 2, type: "staticText", identifier: "txt_title", label: "見出し", value: nil, placeholder: nil,
                                enabled: true, frame: FTRect(x: 16, y: 80, width: 200, height: 30), depth: 1)
        let (outcome, _, _) = await run(FlowStep(action: "scrollToEdge", direction: "up", maxSwipes: 5),
                                        inAppTree: [title, Self.inAppPager])
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(outcome.driverFallback?.contains("the visible content did not move") == true, outcome.driverFallback ?? "nil")
    }

    /// xcuitest モード(XCUITest の補助ドライバが無い)は照会しない
    func testNoConsultWithoutTheXCUITestDriver() async {
        let (outcome, _, log) = await flick(withTypeDriver: false)
        guard case .failed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertFalse(log.entries.contains("xcuitest.snapshot"), "\(log.entries)")
    }
}
