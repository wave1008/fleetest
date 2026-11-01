import XCTest

/// 自動起動が「同じ台の別ポートにランナーが居る」と断ったとき、serve が起動 → 断りを繰り返さず
/// そのポートへ乗り換える配線(ソース走査)。断りは launchBridge の中で分かるので、starter が
/// ポートを控え、コマンドループが毎コマンド読んで本人確認つきで乗り換える。
final class LiveRunnerElsewhereSwitchWiringTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testStarterRemembersTheElsewherePortAndClearsItOnSuccessOrFailure() throws {
        let code = try source("Sources/fleetest/LiveBridgeAutoStarter.swift")
        XCTAssertTrue(code.contains("deviceRunnerElsewhere(_, let elsewhere, _, _) = error {\n                runnerElsewherePort = elsewhere"))
        XCTAssertEqual(code.components(separatedBy: "runnerElsewherePort = nil").count - 1, 2,
                       "成功と本物の失敗の両方で消す")
    }

    func testCommandLoopSwitchesOnlyAfterTheIdentityCheckSaysMine() throws {
        let code = try source("Sources/fleetest/ApiLiveCommand.swift")
        XCTAssertTrue(code.contains("await current.runnerElsewherePort"))
        guard let r = code.range(of: "private func moveToRunnerElsewhere(") else { return XCTFail("helper missing") }
        let body = String(code[r.upperBound...].prefix(1200))
        XCTAssertTrue(body.contains("portIdentity(") && body.contains("== .mine"),
                      "答えるブリッジが自分のデバイスだと確かめてから乗り換える")
    }
}
