// ft_release_device: このセッションの lease の印とデバイスの記憶だけを手放す。デバイス・ブリッジ・アプリには触らない。
// lease は一時フォルダ(本物の .fleetest/ へ書かない)。生きた別プロセスの印には launchd(pid 1)を使う

import XCTest
import FTCore
import FTBridgeClient
@testable import fleetest_mcp

final class MCPReleaseDeviceTests: XCTestCase {
    private final class DriverCounter: @unchecked Sendable { var made = 0 }

    private var driver: FakeDriver!
    private var server: MCPServer!
    private var stateDir: URL!
    private var counter: DriverCounter!
    private let me = ProcessInfo.processInfo.processIdentifier
    private let key = MCPServer.sessionKey([:])

    override func setUpWithError() throws {
        driver = FakeDriver()
        counter = DriverCounter()
        let fake = driver!
        let made = counter!
        server = MCPServer(write: { _ in }, makeDriver: { _ in made.made += 1; return fake },
                           recordSnapshot: { _, _, _ in })
        stateDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MCPReleaseDeviceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        server.deviceLeaseStateDir = stateDir
        server.udids[key] = "UDID-X"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDir)
    }

    private func release(_ args: [String: Any] = [:]) async throws -> String {
        try await server.call(tool: "ft_release_device", args: args).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private func holders() -> [String: Int32] { MCPDeviceLease.liveHolders(stateDir: stateDir, excluding: []) }

    /// 自分の印だけを消す: 別 pid の印は残り、応答がそれを名指しする。release のあとの応答の組み立てが印を書き直さない
    func testRemovesOnlyOurOwnLeaseAndDoesNotRewriteItAfterwards() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        MCPDeviceLease.write(stateDir: stateDir, key: "UDID-X", pid: 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: MCPDeviceLease.leaseURL(stateDir: stateDir, key: "UDID-X", pid: me).path))
        let reply = try await release()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: MCPDeviceLease.leaseURL(stateDir: stateDir, key: "UDID-X", pid: me).path), reply)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: MCPDeviceLease.leaseURL(stateDir: stateDir, key: "UDID-X", pid: 1).path), "他人の印は残す")
        XCTAssertEqual(holders(), ["UDID-X": 1])
        XCTAssertTrue(reply.contains("hold mark removed"), reply)
        XCTAssertTrue(reply.contains("Another session (pid 1) still holds it"), reply)
    }

    /// 自分だけが持っていたときは bridge down が見ないと言う・次のデバイス操作は印を取り直す
    func testSoleHolderSaysBridgeDownNoLongerSeesItAndALaterCallTakesItAgain() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let reply = try await release()
        XCTAssertTrue(reply.contains("`fleetest bridge down` no longer sees this session as holding it"), reply)
        XCTAssertTrue(reply.contains("did not") || reply.contains("were not touched"), reply)
        XCTAssertTrue(holders().isEmpty)
        // 本物の経路では次の呼び出しが udid を引き直して記録する(偽のドライバは引き直さないので、ここで記録を戻す)
        server.udids[key] = "UDID-X"
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        XCTAssertEqual(holders(), ["UDID-X": me], "既存の挙動: 次のデバイスツールが印を書き直す")
    }

    /// このセッションの記憶(ドライバ・木)を捨てる
    func testForgetsTheSessionStateOfThatDevice() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        XCTAssertNotNil(server.lastSnapshots[key])
        // 差し替えドライバは drivers に控えられない(resolveDriver)ので、同じセッションの記憶 bridges で見る
        XCTAssertNotNil(server.bridges[key])
        let reply = try await release()
        XCTAssertNil(server.lastSnapshots[key])
        XCTAssertNil(server.bridges[key])
        XCTAssertNil(server.udids[key])
        XCTAssertTrue(reply.contains("session state forgotten"), reply)
    }

    /// 既定の宛先の記憶がその機を指していたら消す(宛先なしの次の呼び出しが黙って掴み直さない)。別の機の記憶は残す
    func testClearsTheRememberedDefaultTargetOnlyWhenItPointsAtThatDevice() async throws {
        let portKey = "direct:ios:8128:"
        server.udids[portKey] = "UDID-X"
        server.connectedPorts[portKey] = 8128
        server.lastExplicitIOSTarget = (port: 8128, udid: "UDID-X")
        server.seenExplicitIOSPorts = [8128, 8130]
        server.seenExplicitIOSUDIDs = [8128: "UDID-X", 8130: "UDID-Y"]
        server.lastExplicitAndroidSerial = "SERIAL-Z"
        _ = try await release(["udid": "UDID-X"])
        XCTAssertNil(server.lastExplicitIOSTarget)
        XCTAssertEqual(server.seenExplicitIOSPorts, [8130])
        XCTAssertEqual(server.seenExplicitIOSUDIDs, [8130: "UDID-Y"])
        XCTAssertEqual(server.lastExplicitAndroidSerial, "SERIAL-Z", "別のデバイスの記憶は触らない")
        XCTAssertNil(server.connectedPorts[portKey])
    }

    /// Android も serial の鍵で同じ
    func testAndroidSerialIsReleasedToo() async throws {
        let androidKey = MCPServer.sessionKey(["platform": "android", "serial": "emulator-5554"])
        server.connectedAndroidSerials[androidKey] = "emulator-5554"
        server.lastExplicitAndroidSerial = "emulator-5554"
        server.seenExplicitAndroidSerials = ["emulator-5554"]
        MCPDeviceLease.write(stateDir: stateDir, key: "emulator-5554", pid: me)
        let reply = try await release(["platform": "android", "serial": "emulator-5554"])
        XCTAssertNil(server.lastExplicitAndroidSerial)
        XCTAssertTrue(server.seenExplicitAndroidSerials.isEmpty)
        XCTAssertTrue(holders().isEmpty, reply)
    }

    /// ブリッジが無くても手放せる: ドライバを作らず(= ブリッジを起こさず・走査せず)に済む
    func testWorksWithoutAnyBridgeAndCreatesNoDriver() async throws {
        MCPDeviceLease.write(stateDir: stateDir, key: "UDID-GONE", pid: me)
        let reply = try await release(["udid": "UDID-GONE"])
        XCTAssertEqual(counter.made, 0, "手放すためにドライバを作らない")
        XCTAssertTrue(driver.calls.isEmpty, "\(driver.calls)")
        XCTAssertTrue(holders().isEmpty)
        XCTAssertTrue(reply.hasPrefix("Released UDID-GONE"), reply)
        XCTAssertFalse(reply.contains("no running bridge"), reply)
    }

    /// 何も持っていなければそう言う(エラーにしない)
    func testNothingHeldSaysSo() async throws {
        let reply = try await release(["udid": "UDID-NEVER"])
        XCTAssertTrue(reply.hasPrefix("Nothing to release: this session holds nothing on UDID-NEVER."), reply)
        XCTAssertEqual(counter.made, 0)
    }

    /// 他のセッションだけが持っているデバイスでは、自分は何も持っていないと言い、相手の印は消さない
    func testDoesNotTouchAnotherSessionsLeaseWhenWeHoldNothing() async throws {
        MCPDeviceLease.write(stateDir: stateDir, key: "UDID-OTHER", pid: 1)
        let reply = try await release(["udid": "UDID-OTHER"])
        XCTAssertTrue(reply.hasPrefix("Nothing to release"), reply)
        XCTAssertTrue(reply.contains("Another session (pid 1) does hold it"), reply)
        XCTAssertEqual(holders(), ["UDID-OTHER": 1])
    }

    /// 分類: 端末ではなく自分の記憶と印を変えるツール(readOnly でも drivesDevice でもない)・宛先を取る・udid を畳まない
    func testClassification() {
        XCTAssertEqual(MCPServer.toolEffects["ft_release_device"], .releasesSession)
        XCTAssertTrue(MCPServer.toolAcceptsDeviceTarget("ft_release_device"))
        XCTAssertFalse(MCPServer.toolFoldsUDID("ft_release_device"))
        XCTAssertFalse(MCPServer.holdsDeviceLease("ft_release_device"))
        XCTAssertTrue(MCPServer.holdsDeviceLease("ft_snapshot"))
        XCTAssertNotNil(MCPServer.unknownArgumentRefusal(tool: "ft_release_device", args: ["thisDoesNotExist": 1]))
    }
}
