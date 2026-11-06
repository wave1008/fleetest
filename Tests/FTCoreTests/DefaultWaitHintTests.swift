// 操作系(tap 等)が既定の短い待ち(waitSeconds: 省略)で要素を見つけられなかったときの失敗文。
// 画面遷移の直後の tap が既定の待ちで落ちる形を、失敗文だけで直せるようにする(StepExecutor.defaultWaitHint)。

import XCTest
@testable import FTCore

final class DefaultWaitHintTests: XCTestCase {

    private func emptyScreenExecutor() -> StepExecutor {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[]])
        return StepExecutor(driver: driver, typeDriver: nil, isAndroid: false, tunables: RunTunables(),
                            uiFramework: .uikit)
    }

    private func message(_ status: StepResult.Status) -> String {
        if case .failed(let text) = status { return text }
        return "\(status)"
    }

    func testDefaultWaitIsPinned() {
        XCTAssertEqual(StepExecutor.defaultLocatorRetryAttempts, 3)
        XCTAssertEqual(StepExecutor.defaultLocatorRetrySeconds, 0.7, accuracy: 1e-9)
    }

    func testTapWithoutWaitSecondsSaysHowToWaitLonger() async {
        let outcome = await emptyScreenExecutor().execute(
            FlowStep(action: "tap", locator: FlowLocator(id: "next_screen_button")))
        let text = message(outcome.status)
        XCTAssertTrue(text.contains("cannot resolve the locator"), text)
        XCTAssertTrue(text.contains("only about 0.7 s"), text)
        XCTAssertTrue(text.contains("add waitSeconds: to this step"), text)
        XCTAssertEqual(outcome.failureKind, .notFound)
    }

    /// 自分で待ちを決めたステップには言わない(待ちの長さが原因とは言えない)
    func testTapWithExplicitWaitSecondsSaysNothingAboutWaiting() async {
        let outcome = await emptyScreenExecutor().execute(
            FlowStep(action: "tap", locator: FlowLocator(id: "next_screen_button"), timeout: 0.3))
        let text = message(outcome.status)
        XCTAssertTrue(text.contains("cannot resolve the locator"), text)
        XCTAssertFalse(text.contains("waitSeconds"), text)
    }

    /// Android で前面を離れた後(home() の後の tap)は、従えない `waitSeconds:` / `scroll:` でなく、前面に無いことを言う
    func testLeftForegroundHintOnlyWhenAndroidAndAppIsNotInFront() {
        let hint = StepExecutor.leftForegroundHint(isAndroid: true, mayHaveLeft: true, foreground: .value(false), processGone: false)
        XCTAssertTrue(hint?.contains("not in the foreground") == true, hint ?? "nil")
        XCTAssertTrue(hint?.contains("launchApp()") == true, hint ?? "nil")
        XCTAssertFalse(hint?.contains("add waitSeconds") == true)
        // 前面にいる・答えない・印が無い・iOS・プロセスが居ない(落ちた)は従来の文
        XCTAssertNil(StepExecutor.leftForegroundHint(isAndroid: true, mayHaveLeft: true, foreground: .value(true), processGone: false))
        XCTAssertNil(StepExecutor.leftForegroundHint(isAndroid: true, mayHaveLeft: true, foreground: .notAnswerable, processGone: false))
        XCTAssertNil(StepExecutor.leftForegroundHint(isAndroid: true, mayHaveLeft: false, foreground: .value(false), processGone: false))
        XCTAssertNil(StepExecutor.leftForegroundHint(isAndroid: false, mayHaveLeft: true, foreground: .value(false), processGone: false))
        XCTAssertNil(StepExecutor.leftForegroundHint(isAndroid: true, mayHaveLeft: true, foreground: .value(false), processGone: true))
    }
}
