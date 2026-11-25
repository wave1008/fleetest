// XCUITest ランナーの /appstate は、SpringBoard を「前面」と答えるのをホーム画面のアイコンが木にあるときだけにする
// (SpringBoard の state は他のアプリが前面でも runningForeground = appIs("com.apple.springboard") が誤って緑だった)。
// ランナーはデバイスでしか動かないのでソース走査で固定する
import XCTest

final class SpringBoardAppStateSourceTests: XCTestCase {
    func testSpringBoardIsForegroundOnlyWhenItsIconsAreInTheTree() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Runner/FleetestRunnerUITests/BridgeRouter.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let start = source.range(of: "private func handleAppState(") else { return XCTFail("handleAppState が見つからない") }
        let body = String(source[start.upperBound...].prefix(2000))
        XCTAssertTrue(body.contains("req.bundleID == \"com.apple.springboard\""), "SpringBoard を別に扱っていない")
        XCTAssertTrue(body.contains("target.state == .runningForeground && target.icons.firstMatch.exists"),
                      "SpringBoard の前面をアイコンの有無で確かめていない")
    }
}

/// XCUITest ランナーは上端の帯の高さを SpringBoard のステータスバーの枠の下端から申告する(アプリの safeAreaInsets は読めない)。
/// 不明(.unknown)のままだと、帯へ寄った戻るボタンへの tap がステータスバーに当たって何も押さずに ✅ だった
final class RunnerStatusBarBandSourceTests: XCTestCase {
    func testRunnerReportsTheStatusBarBottomAsTheTopBand() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Runner/FleetestRunnerUITests/BridgeRouter.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("safeAreaTop: statusBarBand(screen: cap.screen)"), "スナップショットが帯の高さを申告していない")
        XCTAssertFalse(source.contains("safeAreaTop: .unknown)"), "帯の高さを不明のまま申告している")
        XCTAssertTrue(source.contains("statusBars.firstMatch"), "ステータスバーの枠を読んでいない")
    }
}
