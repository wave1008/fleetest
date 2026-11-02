// 起こしたアプリのプロセスが居ないのに、木の持ち主が別のアプリ(同じ id を持つ)になっている形を、
// DSL(StepExecutor)も MCP(同じ executor)も撃たず・通さずに断る。判定は FTCore の `AppProcessGone` の1箇所。
// 前面が別アプリというだけ(プロセスは居る・判定できない)では断らない = openURL・権限ダイアログへ移る正しいシナリオを赤にしない。

import XCTest
@testable import FTCore

final class AppProcessGoneTests: XCTestCase {

    private let app = "com.example.app"
    private let other = "com.example.other"

    // MARK: - 判定

    func testGoneOnlyWhenTheOwnerDiffersAndTheProcessIsKnownToBeAbsent() async {
        let gone = await AppProcessGone.isGone(launched: app, owner: other, processRunning: { false })
        XCTAssertTrue(gone)
        let running = await AppProcessGone.isGone(launched: app, owner: other, processRunning: { true })
        XCTAssertFalse(running, "プロセスが居る = 別アプリへ移っただけ")
        let unknown = await AppProcessGone.isGone(launched: app, owner: other, processRunning: { nil })
        XCTAssertFalse(unknown, "判定できないときは断らない")
    }

    func testDoesNotAskWhenTheOwnerIsTheLaunchedAppOrASystemSurface() async {
        let asked = LockedBox()
        for owner in [app, ForegroundState.springboard, "com.android.systemui", nil] as [String?] {
            let gone = await AppProcessGone.isGone(launched: app, owner: owner, processRunning: { asked.hit(); return false })
            XCTAssertFalse(gone, "\(owner ?? "nil")")
        }
        XCTAssertEqual(asked.count, 0, "通常の呼び出しや結論の変わらない持ち主で adb を払わない")
    }

    final class LockedBox: @unchecked Sendable {
        private(set) var count = 0
        func hit() { count += 1 }
    }

    // MARK: - StepExecutor(DSL と MCP が共有する門)

    private func element(_ id: String) -> ElementInfo {
        ElementInfo(ref: 1, type: "button", identifier: id, label: nil, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 10, y: 10, width: 100, height: 40), depth: 1)
    }

    private func make(owner: String, running: Bool?, launched: String? = "com.example.app")
        -> (StepExecutor, FakeAppDriver, CallLog) {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [[element("btn_back")]])
        driver.sessionBundleIDs = [owner]
        let executor = StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())
        executor.launchedBundleID = launched
        executor.appProcessRunning = { _ in running }
        return (executor, driver, log)
    }

    func testTapOnAnotherAppsTreeIsRefusedBeforeFiringWhenTheProcessIsGone() async {
        let (executor, _, log) = make(owner: other, running: false)
        let outcome = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn_back")))
        guard case .failed(let reason) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(reason.contains("is not running"), reason)
        XCTAssertTrue(reason.contains(other), reason)
        XCTAssertTrue(reason.contains("nothing was sent"), reason)
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("primary.tap") }, "\(log.entries)")
    }

    func testTypeWithASelectorIsRefusedToo() async {
        let (executor, _, log) = make(owner: other, running: false)
        let outcome = await executor.execute(FlowStep(action: "type", locator: FlowLocator(id: "btn_back"), text: "x"))
        guard case .failed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("primary.type") }, "\(log.entries)")
    }

    func testExistThatWouldPassOnAnotherAppsTreeFails() async {
        let (executor, _, _) = make(owner: other, running: false)
        let outcome = await executor.execute(FlowStep(assert: "exists", locator: FlowLocator(id: "btn_back"), timeout: 1))
        guard case .failed(let reason) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(reason.contains("is not running"), reason)
    }

    func testScrollToOnAnotherAppsTreeIsRefusedWithoutSwiping() async {
        let (executor, _, log) = make(owner: other, running: false)
        let outcome = await executor.execute(FlowStep(action: "scrollTo", locator: FlowLocator(id: "missing"), direction: "down"))
        guard case .failed(let reason) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(reason.contains("is not running"), reason)
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("primary.swipe") }, "\(log.entries)")
    }

    /// 陰性対照: プロセスが居る(別アプリへ移っただけ)・判定できない・起こしていない・持ち主が同じ ときは通す
    func testStillPassesWhenTheProcessIsRunningUnknownOrNotTracked() async {
        for (running, launched) in [(Optional(true), Optional("com.example.app")), (nil, "com.example.app"),
                                    (false, nil)] {
            let (executor, _, log) = make(owner: other, running: running, launched: launched)
            let tap = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn_back")))
            XCTAssertTrue(StepExecutor.isSuccess(tap.status), "\(String(describing: running)) \(String(describing: launched)): \(tap.status)")
            XCTAssertTrue(log.entries.contains { $0.hasPrefix("primary.tap") }, "\(log.entries)")
        }
        let (same, _, _) = make(owner: app, running: false)
        let outcome = await same.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn_back")))
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "持ち主が起こしたアプリなら照会しない: \(outcome.status)")
    }
}
