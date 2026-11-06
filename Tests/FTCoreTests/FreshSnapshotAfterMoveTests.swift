// 直前のステップが画面を動かしうる操作(払い・tap 等)なら、次のロケータ操作の解決の 1 枚はキャッシュを迂回して撮る
// (StepExecutor.nextResolveBypassesCache)。Android の a11y キャッシュはスクロール後に古い座標を
// 返すことがあり、整定(新鮮な木)で止まったと確かめても、続く tap が素取得の古い座標を叩いていた。

import XCTest
@testable import FTCore

final class FreshSnapshotAfterMoveTests: XCTestCase {
    private func button() -> ElementInfo {
        ElementInfo(ref: 1, type: "button", identifier: "cb_agree", label: "同意", value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 16, y: 300, width: 200, height: 48), depth: 1)
    }

    /// scroll → exist → tap: tap の解決で迂回付きの snapshot が 1 回増える(exist は消費しない)
    func testTapAfterAScrollStepBypassesTheCacheOnce() async throws {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [[button()]])
        driver.bypassSupported = true
        let executor = StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())

        _ = await executor.execute(FlowStep(action: "scroll", direction: "up", maxSwipes: 1))
        let afterScroll = driver.bypassedSnapshotCount
        XCTAssertGreaterThan(afterScroll, 0, "整定は迂回付きで撮るはず(前提)")
        _ = await executor.execute(FlowStep(assert: "exists", locator: FlowLocator(id: "cb_agree"), timeout: 0))
        // 操作の直後の最初の検証の読みは迂回する(古いキャッシュで「飲まれた」と読まない = AssertionReadAfterOwnMoveTests)。
        // 解決の印(nextResolveBypassesCache)は消費しない
        let afterExist = driver.bypassedSnapshotCount
        XCTAssertEqual(afterExist, afterScroll + 1, "操作の直後の最初の検証の読みだけ迂回する")
        XCTAssertTrue(executor.nextResolveBypassesCache, "exist は解決の印を消費しない")

        let outcome = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "cb_agree")))

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.bypassedSnapshotCount, afterExist + 1, "tap の解決の 1 枚だけ迂回して撮るはず")
        XCTAssertTrue(executor.nextResolveBypassesCache, "印は解決で消費し、成功した tap 自身が次の解決のために立て直す")
    }

    /// tap → tap: 最初の tap の解決は素取得、2 つ目の tap の解決の 1 枚は迂回(tap も画面を変える操作 = `StepAction.mayChangeScreen`)。
    /// 素取得のままだと tap の前の古い木で「押せる」と読み、押せない骨組みの行を ok で撃った(CMP の Android・9/9)。
    /// 費用は Android で操作の直後のロケータ操作 1 回あたり迂回の読み 1 回
    func testTapAfterTapBypassesTheCacheOnce() async throws {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [[button()]])
        driver.bypassSupported = true
        let executor = StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())

        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "cb_agree")))
        let afterFirst = driver.bypassedSnapshotCount
        XCTAssertEqual(afterFirst, 0, "最初の tap の解決は素取得")
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "cb_agree")))

        XCTAssertEqual(driver.bypassedSnapshotCount, 1, "2 つ目の tap の解決の 1 枚だけ迂回")
    }

    /// 迂回を持たないドライバ(iOS in-app / XCUITest)では印が立っても素取得(bypassesCache の真理値表)
    func testDriverWithoutBypassIsUnaffected() async throws {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [[button()]])
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())

        _ = await executor.execute(FlowStep(action: "scroll", direction: "up", maxSwipes: 1))
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "cb_agree")))

        XCTAssertEqual(driver.bypassedSnapshotCount, 0)
    }
}
