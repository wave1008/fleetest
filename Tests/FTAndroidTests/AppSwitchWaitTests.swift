// アプリを切り替えるキー(HOME・APP_SWITCH)の後は、Android の入力の配送が切り替えを待つ上限(AOSP InputDispatcher の
// APP_SWITCH_TIMEOUT = 500ms)が過ぎるまで次の入力を撃たない。上限で配送待ちの入力が捨てられ、ドラッグが途中で切れる

import XCTest
@testable import FTAndroid

final class AppSwitchWaitTests: XCTestCase {

    /// 既定は OS の定数と同じ 500ms(リテラルで固定 = 既定を戻す変更を落とす)
    func testTimeoutIsPinnedToTheOSConstant() {
        XCTAssertEqual(AndroidDriver.appSwitchTimeout, .milliseconds(500))
    }

    func testRemainingWaitIsTheRestOfTheTimeout() {
        XCTAssertEqual(AndroidDriver.appSwitchWaitRemaining(elapsed: .zero), .milliseconds(500))
        XCTAssertEqual(AndroidDriver.appSwitchWaitRemaining(elapsed: .milliseconds(320)), .milliseconds(180))
        XCTAssertEqual(AndroidDriver.appSwitchWaitRemaining(elapsed: .milliseconds(500)), .zero)
        XCTAssertEqual(AndroidDriver.appSwitchWaitRemaining(elapsed: .milliseconds(900)), .zero,
                       "整定待ちの間に過ぎていれば待たない")
    }

    /// home と openAppSwitcher はキーの後に待ちを通す(ソース走査。片方だけに入れると、もう片方の直後のドラッグが切れる)
    func testHomeAndAppSwitcherWaitOutTheAppSwitch() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FTAndroid/AndroidDriver.swift"), encoding: .utf8)
        for signature in ["public func home() async throws {", "public func openAppSwitcher() async throws {"] {
            guard let start = source.range(of: signature),
                  let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex) else {
                return XCTFail("\(signature) が見つからない — テストを見直すこと")
            }
            let body = source[start.upperBound..<end.lowerBound]
            XCTAssertTrue(body.contains("await waitOutAppSwitch(since: sentAt)"), "\(signature) が切り替えの上限を待っていない")
        }
    }
}
