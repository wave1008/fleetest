import XCTest
import FTBridgeClient
@testable import fleetest

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
        XCTAssertEqual(code.components(separatedBy: "runnerElsewherePort = nil").count - 1, 3,
                       "成功・本物の失敗・ランナーが居なくなった(誰も listen していない)ときに消す")
    }

    func testCommandLoopSwitchesOnlyAfterTheIdentityCheckSaysMine() throws {
        let code = try source("Sources/fleetest/ApiLiveCommand.swift")
        XCTAssertTrue(code.contains("await current.runnerElsewherePort"))
        guard let r = code.range(of: "private func moveToRunnerElsewhere(") else { return XCTFail("helper missing") }
        let body = String(code[r.upperBound...].prefix(2400))
        XCTAssertTrue(body.contains("portIdentity(") && body.contains("== .mine"),
                      "答えるブリッジが自分のデバイスだと確かめてから乗り換える")
    }

    /// 別ポートのランナーが居る間は撃ち直さない(毎コマンド idle → starting へ入れ直して理由が載らず約7秒止まっていた)。
    /// 居なくなったとき(誰も listen していない)だけ起動へ戻る
    func testSkipHoldsWhileTheElsewhereRunnerListens() throws {
        XCTAssertTrue(LiveBridgeAutoStarter.elsewhereSkipHolds(probe: .answered))
        XCTAssertTrue(LiveBridgeAutoStarter.elsewhereSkipHolds(probe: .timedOut))
        XCTAssertTrue(LiveBridgeAutoStarter.elsewhereSkipHolds(probe: .transportFailed))
        XCTAssertFalse(LiveBridgeAutoStarter.elsewhereSkipHolds(probe: .notBound))
        let code = try source("Sources/fleetest/LiveBridgeAutoStarter.swift")
        guard let r = code.range(of: "func noteConnectionRefused(") else { return XCTFail("missing") }
        let body = String(code[r.upperBound...].prefix(1500))
        XCTAssertTrue(body.contains("elsewhereSkipHolds(probe:") && body.contains("return suffix()"),
                      "別ポートのランナーを理由にした断りの間は、起動へ入れ直さず理由の文を返す")
    }

    /// 答えない別ポートのランナーに /status 2 本 + probe を毎コマンド払わない。窓の中は省き、窓が尽きれば撃ち直す
    func testSilentElsewhereRunnerIsSkippedOnlyWithinTheWindow() async {
        let starter = LiveBridgeAutoStarter(
            repoRoot: URL(fileURLWithPath: "/tmp"), udid: "U", port: 8151, physical: false, wired: false)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let silent = await starter.isElsewhereSilent(now: t0)
        XCTAssertFalse(silent)
        await starter.noteElsewhereSilent(now: t0)
        let inWindow = await starter.isElsewhereSilent(now: t0.addingTimeInterval(
            LiveBridgeAutoStarter.elsewhereSilenceWindowSeconds - 0.1))
        XCTAssertTrue(inWindow)
        let expired = await starter.isElsewhereSilent(now: t0.addingTimeInterval(
            LiveBridgeAutoStarter.elsewhereSilenceWindowSeconds))
        XCTAssertFalse(expired, "窓が尽きたら撃ち直す = 戻ったランナーが永久に使えなくならない")
    }

    func testProbeAnswerOrNoListenerClearsTheSilenceMemo() async {
        let starter = LiveBridgeAutoStarter(
            repoRoot: URL(fileURLWithPath: "/tmp"), udid: "U", port: 8151, physical: false, wired: false)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for answer in [BridgeDiscovery.StatusProbe.answered, .notBound] {
            await starter.noteElsewhereProbe(.timedOut, now: t0)
            let held = await starter.isElsewhereSilent(now: t0)
            XCTAssertTrue(held)
            await starter.noteElsewhereProbe(answer, now: t0)
            let cleared = await starter.isElsewhereSilent(now: t0)
            XCTAssertFalse(cleared)
        }
        await starter.noteElsewhereProbe(.transportFailed, now: t0)
        let transport = await starter.isElsewhereSilent(now: t0)
        XCTAssertTrue(transport)
    }

    func testMoveBailsOutOnTheFirstSilentStatusAndCommandLoopHonoursTheMemo() throws {
        let code = try source("Sources/fleetest/ApiLiveCommand.swift")
        guard let r = code.range(of: "private func moveToRunnerElsewhere(") else { return XCTFail("helper missing") }
        let body = String(code[r.upperBound...].prefix(2400))
        guard let silent = body.range(of: "noteElsewhereSilent()"),
              let resolve = body.range(of: "XCUIBridgeResolver.resolve(") else { return XCTFail("shape") }
        XCTAssertLessThan(silent.lowerBound, resolve.lowerBound, "resolve(+portIdentity の 3 秒)の前に無応答で抜ける")
        XCTAssertTrue(code.contains("!(await current.isElsewhereSilent())"), "窓の中は乗り換えの試行を省く")
    }
}
