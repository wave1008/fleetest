// 落ちた対象アプリを AppAttachDriver が activate で起こさないことの固定。起こすと in-app ブリッジ無しで最初の画面から
// 起動し、撃ち直した操作が読んでいない画面で成功する(ランナーの 503 = BridgeRouter.requireLiveApp の意図)

import XCTest
@testable import FTBridgeClient
import FTCore

final class AppAttachDriverAppGoneTests: XCTestCase {
    private static let target = "com.example.target"
    private static let appNotRunning = #"{"error":"the target app is not running"}"#

    private func status(session: String) -> String {
        #"{"ready":true,"device":"iPhone","osVersion":"27.0","sessionBundleID":"\#(session)"}"#
    }

    private func driver(_ stub: RecordingStubServer) -> AppAttachDriver {
        AppAttachDriver(port: stub.port, host: BridgeEndpoint.loopbackHost, bundleID: Self.target, physicalUDID: nil)
    }

    /// 503 でセッションが自分のアプリ = 自分のアプリが落ちている → activate せずに 503 を返す
    func testRunnerSaysOwnAppIsNotRunningIsNotRevived() async throws {
        let stub = try RecordingStubServer(body: #"{"ok":true,"foreground":true}"#)
        defer { stub.stop() }
        stub.setResponse(status: 503, body: Self.appNotRunning, for: "POST /drag")
        stub.setResponse(status: 200, body: status(session: Self.target), for: "GET /status")
        let driver = driver(stub)
        do {
            try await driver.drag(fromX: 0, fromY: 0, toX: 0, toY: 100, pressSeconds: 0, durationSeconds: 0.2)
            XCTFail("落ちたアプリへの操作は 503 のまま返すはず")
        } catch DriverError.badResponse(let code, _) {
            XCTAssertEqual(code, 503)
        }
        XCTAssertEqual(stub.paths.filter { $0 == "POST /drag" }.count, 1, "撃ち直した: \(stub.paths)")
        XCTAssertFalse(stub.body(for: "POST /session")?.contains("\"activate\":true") == true,
                       "activate で起こした: \(stub.paths)")
    }

    /// 503 でもセッションが別のアプリを指していた(付け直しが揃わなかった)ときは付け直して1回だけ撃ち直す
    func testRunnerSessionOnAnotherAppIsReattached() async throws {
        let stub = try RecordingStubServer(body: #"{"ok":true,"foreground":true}"#)
        defer { stub.stop() }
        stub.setResponse(status: 503, body: Self.appNotRunning, for: "POST /drag")
        stub.setResponse(status: 200, body: status(session: "com.example.other"), for: "GET /status")
        let driver = driver(stub)
        _ = try? await driver.drag(fromX: 0, fromY: 0, toX: 0, toY: 100, pressSeconds: 0, durationSeconds: 0.2)
        XCTAssertEqual(stub.paths.filter { $0 == "POST /drag" }.count, 2, "\(stub.paths)")
        XCTAssertTrue(stub.body(for: "POST /session")?.contains("\"activate\":true") == true, "\(stub.paths)")
    }

    /// 前面に居ないアプリは、プロセスが居ないと確かめられたら activate しない(操作も撃たない)
    func testAttachDoesNotActivateWhenTheProcessIsGone() async throws {
        let stub = try RecordingStubServer()  // /appstate の答えに foreground が無い = 前面と言えない
        defer { stub.stop() }
        let driver = driver(stub)
        driver.appIsRunning.withLock { $0 = { _ in false } }
        do {
            try await driver.swipe(.up)
            XCTFail("居ないアプリへの操作は断るはず")
        } catch DriverError.badResponse(let code, let body) {
            XCTAssertEqual(code, 503)
            XCTAssertTrue(body.contains("is not running (it crashed or exited)"), body)
        }
        XCTAssertEqual(stub.paths, ["POST /appstate"], "activate も操作も撃たない: \(stub.paths)")
    }

    /// シナリオ実行の入口は、回復の activate の前に聞く生死の口を全部の XCUITest 側のドライバへ渡す
    /// (`appIsRunning` は既定 nil = 渡し忘れが型で止まらない。MCP・探索は渡していて、シナリオ実行だけが落ちたアプリを起こしていた)
    func testScenarioRunnerPassesTheAppProbeToEveryRecoveringDriver() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FTScenarioRunner/ScenarioRunnerMain.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let sites = source.components(separatedBy: "SessionRecoveryDriver(").dropFirst()
        XCTAssertFalse(sites.isEmpty)
        for site in sites {
            let call = site.prefix(300)  // 呼び出しの引数(2〜3行)が収まる長さ
            XCTAssertTrue(call.contains("appIsRunning: simulatorAppProbe"), "生死の口を渡していない: \(call.prefix(120))")
        }
        XCTAssertTrue(source.contains("attach.appIsRunning.withLock { $0 = simulatorAppProbe }"))
    }

    /// シナリオ自身が止めたアプリは、生死の照会より先に「止めたアプリ」の断り(appStoppedBySession)で返す
    /// (シナリオ実行は両方の口を設定する。照会を先にすると汎用の 503 に化けて失敗の種別が変わる)
    func testStoppedByScenarioRefusalWinsOverTheProcessProbe() async throws {
        let stub = try RecordingStubServer()
        defer { stub.stop() }
        let driver = driver(stub)
        driver.revivalRefusal.withLock { $0 = { "stopped" } }
        driver.appIsRunning.withLock { $0 = { _ in false } }
        do {
            try await driver.swipe(.up)
            XCTFail("止めたアプリへの操作は断るはず")
        } catch let error as StoppedAppRefusal {
            XCTAssertEqual(error.stepFailureKind, .appStoppedBySession)
        }
    }

    /// 居る・判定できない(nil)ときはこれまでどおり activate してから撃つ
    func testAttachActivatesWhenTheProcessIsRunningOrUnknown() async throws {
        for answer in [true, nil] as [Bool?] {
            let stub = try RecordingStubServer()
            defer { stub.stop() }
            let driver = driver(stub)
            driver.appIsRunning.withLock { $0 = { _ in answer } }
            try await driver.swipe(.up)
            XCTAssertEqual(stub.paths, ["POST /appstate", "POST /session", "POST /swipe"], "\(stub.paths)")
        }
    }
}
