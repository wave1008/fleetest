import XCTest
@testable import FTCore

/// 撃つ前に「有効になるのを待った」時間で waitSeconds を使い切っても、届けずに断られた操作の撃ち直しの1回は撃つ。
/// 失敗文は iosAlertHandler の登録の有無で言い分ける
final class OI392AlertRetryBudgetTests: XCTestCase {

    private func disabledTarget() -> ElementInfo {
        ElementInfo(ref: 1, type: "button", identifier: "target", label: nil, value: nil, placeholder: nil,
                    enabled: false, frame: FTRect(x: 1, y: 1, width: 10, height: 10), depth: 0)
    }

    private func alertTree() -> [ElementInfo] {
        [ElementInfo(ref: 100, type: "alert", identifier: nil, label: "写真ライブラリへのアクセス", value: nil,
                     placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 0, width: 300, height: 200), depth: 0),
         ElementInfo(ref: 9, type: "button", identifier: nil, label: "許可しない", value: nil, placeholder: nil,
                     enabled: true, frame: FTRect(x: 1, y: 1, width: 10, height: 10), depth: 1)]
    }

    private let blocked = DriverError.systemAlertBlocked(
        detail: "a system alert is in front of the app" + StepExecutor.bridgeAlertHandlerAdvice)

    /// 有効にならない対象を waitSeconds いっぱい待ってから撃つ → 断られる。待った時間で予算が尽きていても閉じて撃ち直す
    func testTheRetryIsSentEvenWhenWaitingForEnabledUsedUpTheBudget() async {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[disabledTarget()]])
        primary.tapErrors = [blocked]
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [alertTree()])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: false),
                                      SystemAlertProbeResponse(present: true, title: "写真ライブラリへのアクセス",
                                                               buttons: ["許可しない"]),
                                      SystemAlertProbeResponse(present: false)]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false, tunables: RunTunables())
        executor.systemAlertWatchlist.register(SystemAlertRule(alert: "*写真ライブラリ*", button: "許可しない"))
        let outcome = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "target"), timeout: 0.3))
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "\(outcome.status)")
        XCTAssertEqual(log.entries.filter { $0.hasPrefix("primary.tap") }, ["primary.tap(ref:1)", "primary.tap(ref:1)"],
                       "\(log.entries)")
        XCTAssertTrue(outcome.notes.contains(.systemAlertRetried), "\(outcome.notes)")
    }

    /// 登録があるのに落ちた回は「自動で閉じる」と言わず、種別(systemAlertBlocked)は保つ
    func testRegisteredFailureDoesNotPromiseAutomaticClosing() {
        let text = (StepExecutor.noteAlertRegistration(blocked, registered: true, canClose: true) as? DriverError)?.errorDescription ?? ""
        XCTAssertFalse(text.contains("closes it automatically"), text)
        XCTAssertTrue(text.contains("iosAlertHandler is registered"), text)
        if case DriverError.systemAlertBlocked? = StepExecutor.noteAlertRegistration(blocked, registered: true, canClose: true) as? DriverError {} else {
            XCTFail("種別が変わった")
        }
    }

    /// 閉じる手段(XCUITest の fallback)が無い構成では「時間内に閉じられなかった」と言わず、閉じられない事実を言う
    func testRegisteredWithoutAClosingMeansSaysItCannotClose() {
        let text = (StepExecutor.noteAlertRegistration(blocked, registered: true, canClose: false) as? DriverError)?.errorDescription ?? ""
        XCTAssertFalse(text.contains("did not close this alert in time"), text)
        XCTAssertFalse(text.contains("closes it automatically"), text)
        XCTAssertTrue(text.contains("cannot close system alerts during the step (no XCUITest fallback)"), text)
    }

    /// 登録が無い回は、ブリッジの案内(iosAlertHandler で閉じられる)がそのまま正しい
    func testUnregisteredFailureKeepsTheBridgeAdvice() {
        let text = (StepExecutor.noteAlertRegistration(blocked, registered: false, canClose: true) as? DriverError)?.errorDescription ?? ""
        XCTAssertTrue(text.contains("closes it automatically"), text)
    }

    /// 他の種類のエラーは触らない
    func testOtherErrorsPassThrough() {
        let other = DriverError.badResponse(status: 500, body: "x")
        XCTAssertEqual((StepExecutor.noteAlertRegistration(other, registered: true, canClose: true) as? DriverError)?.errorDescription,
                       other.errorDescription)
    }
}
