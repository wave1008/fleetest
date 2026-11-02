// MCP 側の残件の直しを固定する。
// 各テストは直しを外す変異(MutationCases の案)で落ちる向きと、逆向き(常に出す)の両方を持つ。

import XCTest
import FTCore
import FTBridgeClient
@testable import fleetest_mcp

final class MCPOpenIssuesSweepTests: XCTestCase {

    private let iosContext = DriverErrorContext(bridge: .iosXCUITest, physicalDevice: false)

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func facts() -> ConnectionFacts {
        ConnectionFacts(scan: { _ in [] }, mayBeListening: { _, _ in true }, ownerAlive: { _, _ in nil },
                        probeStatus: { _, _ in .timedOut }, androidListed: { [] })
    }

    private func element(ref: Int, y: Double, height: Double = 40, id: String = "row") -> ElementInfo {
        ElementInfo(ref: ref, type: "Button", identifier: id, label: id, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: 10, y: y, width: 100, height: height), depth: 1)
    }

    // MARK: - 包まれた接続拒否では記憶を捨てない

    func testWrappedRefusalIsRecognisedByKindOnly() {
        let refused = DriverError.bridgeConnectionRefused(context: iosContext, detail: "x")
        XCTAssertTrue(MCPServer.isWrappedConnectionRefusal(MCPAnnotatedError(underlying: refused, suffix: "")))
        XCTAssertFalse(MCPServer.isWrappedConnectionRefusal(refused), "包まれていない拒否は従来どおり復帰の対象")
        XCTAssertFalse(MCPServer.isWrappedConnectionRefusal(MCPAnnotatedError(
            underlying: DriverError.badResponse(status: 500, body: ""), suffix: "")))
        XCTAssertFalse(MCPServer.isWrappedConnectionRefusal(MCPError("connection refused")), "文言では決めない")
    }

    func testKeepsMemoryOnWrappedRefusalAndDropsItOtherwise() async {
        let refused = DriverError.bridgeConnectionRefused(context: iosContext, detail: "x")
        for keeps in [true, false] {
            let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() }, recordSnapshot: { _, _, _ in })
            let key = "direct:ios:8100"
            server.connections[key] = "port 8100"
            server.connectedPorts[key] = 8100
            let text = await server.iosConnectionLostHint(
                refused, key: key, connection: "port 8100", facts: facts(), mayHaveTakenEffect: false, keepsMemory: keeps)
            XCTAssertEqual(server.connectedPorts[key] != nil, keeps, text)
            XCTAssertEqual(text.contains("still remembers"), keeps, text)
            XCTAssertEqual(text.contains("remembered device was dropped"), !keeps, text)
        }
    }

    func testCallCatchPassesTheWrappedRefusalFlag() throws {
        let dispatch = try source("Sources/fleetest-mcp/MCPServer+Dispatch.swift")
        XCTAssertTrue(dispatch.contains("keepsMemory: Self.isWrappedConnectionRefusal(error)"))
    }

    // MARK: - 全手の後の読みが失敗しても投げられた case を抱える

    func testUnreadableAfterBatchKeepsTheThrownError() async {
        let driver = FakeDriver()
        driver.foregroundBundleID = "com.example.app"
        driver.snapshotsFailAfterCallPrefix = "tap("
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        do {
            _ = try await server.call(tool: "ft_batch", args: ["steps": "tap '#login_btn'"])
            XCTFail("全手の後の読みが失敗したのに成功と返した")
        } catch {
            let annotated = error as? MCPAnnotatedError
            XCTAssertNotNil(annotated, "投げられた case を抱えない失敗に畳まれた: \(error)")
            XCTAssertTrue(annotated?.underlying is FakeDriver.Boom)
            XCTAssertTrue(error.localizedDescription.contains("All 1 step(s) were sent"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("Do not re-send the steps"), error.localizedDescription)
        }
    }

    func testUnreadableAfterBatchMessageKeepsTheStepLines() {
        let text = MCPServer.unreadableAfterBatchMessage(
            stepLines: ["1. tap — ok (5ms)"], stepCount: 1, error: MCPError("boom"), unobservedTouches: [])
        XCTAssertTrue(text.hasPrefix("1. tap — ok (5ms)"), text)
        XCTAssertTrue(text.contains("boom"), text)
    }

    // MARK: - OI-115 ft_scroll_to の見出しと注記

    func testScrollToHeadlineDoesNotClaimReachWhenUnderTheKeyboard() {
        let under = MCPServer.scrollToHeadline("#f", swipes: 2, hiddenUnderChrome: false, underKeyboard: true)
        XCTAssertFalse(under.contains("scrolled to"), under)
        XCTAssertTrue(under.contains("under the soft keyboard"), under)
        XCTAssertEqual(MCPServer.scrollToHeadline("#f", swipes: 2, hiddenUnderChrome: false, underKeyboard: false),
                       "scrolled to \"#f\"")
    }

    func testScrollToWiresTheKeyboardJudgementFromTheSameOcclusionAsTheNote() throws {
        let snapshot = try source("Sources/fleetest-mcp/MCPServer+Snapshot.swift")
        XCTAssertTrue(snapshot.contains("landedUnderKeyboard = KeyboardOcclusion.resolve("))
        XCTAssertEqual(snapshot.components(separatedBy: "underKeyboard: landedUnderKeyboard").count - 1, 2,
                       "両方の成功本文(アラート前面・通常)が同じ判定を渡す")
    }

    // MARK: - 同じ udid の port 違いは 1 台

    func testSamePortMovedOnTheSameUDIDIsOneDevice() {
        var seen: Set<UInt16> = []
        var udids: [UInt16: String] = [:]
        MCPServer.dropSupersededPorts(seen: &seen, udids: &udids, port: 8123, udid: "U1")
        MCPServer.dropSupersededPorts(seen: &seen, udids: &udids, port: 8137, udid: "U1")
        XCTAssertEqual(seen, [8137], "同じ udid の古い port を数え続けた")
        MCPServer.dropSupersededPorts(seen: &seen, udids: &udids, port: 8140, udid: "U2")
        XCTAssertEqual(seen, [8137, 8140], "別の udid は別の台")
        MCPServer.dropSupersededPorts(seen: &seen, udids: &udids, port: 8150, udid: nil)
        MCPServer.dropSupersededPorts(seen: &seen, udids: &udids, port: 8151, udid: nil)
        XCTAssertEqual(seen, [8137, 8140, 8150, 8151], "udid が分からない port は同一と言えないので外さない")
    }

    func testRememberResolvedTargetFoldsTheMovedPort() {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() }, recordSnapshot: { _, _, _ in })
        server.rememberResolvedTarget(platform: "ios", args: ["port": 8123], iosPort: 8123, iosUDID: "U1", androidSerial: nil)
        server.rememberResolvedTarget(platform: "ios", args: ["udid": "U1"], iosPort: 8137, iosUDID: "U1", androidSerial: nil)
        XCTAssertEqual(server.seenExplicitIOSPorts, [8137])
        let fold = server.foldInRememberedDevice(["platform": "ios"])
        if case .ambiguous = fold { XCTFail("1台を2台と数えて宛先なしの呼び出しを断った") }
    }

    func testForgetConnectionClearsThePortUDIDEntry() {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() }, recordSnapshot: { _, _, _ in })
        server.rememberResolvedTarget(platform: "ios", args: ["port": 8123], iosPort: 8123, iosUDID: "U1", androidSerial: nil)
        server.connectedPorts["k"] = 8123
        server.forgetConnection("k")
        XCTAssertNil(server.seenExplicitIOSUDIDs[8123])
        XCTAssertFalse(server.seenExplicitIOSPorts.contains(8123))
    }

    func testVersionGuardRefusalIsNotCountedAsDrivenAndLeavesNoLease() async throws {
        let driver = FakeDriver()
        driver.statusResponse = StatusResponse(ready: true, device: "Pixel", osVersion: "14", sessionBundleID: nil,
                                               protocolVersion: BridgeAPI.bridgeProtocolVersion - 1)
        let stateDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("OI68-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in },
                               checksVersionOnInjectedDriver: true)
        server.deviceLeaseStateDir = stateDir
        let args: [String: Any] = ["platform": "android", "serial": "emulator-5554"]
        do {
            _ = try await server.call(tool: "ft_snapshot", args: args)
            XCTFail("版ズレのまま通った")
        } catch {
            XCTAssertTrue(error is MCPVersionGuardRefusal, "\(error)")
        }
        XCTAssertTrue(MCPDeviceLease.liveHolders(stateDir: stateDir, excluding: []).isEmpty,
                      "断った MCP が使用中の印を握った")
        // 逆向き: 押し通した呼び出しは印を置く
        _ = try await server.call(tool: "ft_snapshot", args: args.merging(["allowVersionSkew": true]) { $1 })
        XCTAssertEqual(MCPDeviceLease.liveHolders(stateDir: stateDir, excluding: []).keys.sorted(), ["emulator-5554"])
    }

    func testDriverRemembersTheTargetOnlyAfterTheVersionGuard() throws {
        let driver = try source("Sources/fleetest-mcp/MCPServer+Driver.swift")
        let parts = driver.components(separatedBy: "try await enforceVersion(driver: created, key: key, args: args)")
        XCTAssertEqual(parts.count, 3)
        XCTAssertFalse(parts[0].contains("rememberResolvedTarget(platform: \"ios\", args: args,\n                                   iosPort: resolved.port"))
        XCTAssertTrue(parts[1].hasPrefix("\n            // **記録は版ガードを通った後**") || parts[1].contains("rememberResolvedTarget"))
        XCTAssertTrue(parts[2].contains("rememberResolvedTarget(platform: \"ios\", args: args,\n                                   iosPort: resolved.port"),
                      "直接ポート経路の記録が版ガードの前に戻った")
    }

    // MARK: - OI-84 ref の経路が画面の上の外を撃たない

    func testAboveScreenJudgementIsSharedAndDirectional() {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        XCTAssertTrue(TapTargetGeometry.isPointAboveScreen(x: 10, y: -1, screen: screen))
        XCTAssertFalse(TapTargetGeometry.isPointAboveScreen(x: 10, y: 0, screen: screen))
        XCTAssertFalse(TapTargetGeometry.isPointAboveScreen(x: 10, y: 900, screen: screen), "下の外は含めない")
        XCTAssertFalse(TapTargetGeometry.isPointAboveScreen(x: 10, y: -5, screen: FTRect(x: 0, y: 0, width: 0, height: 0)),
                       "画面が分からなければ外れと読まない")
        XCTAssertTrue(TapTargetGeometry.centreIsAboveScreen(element(ref: 1, y: -100), screen: screen))
        XCTAssertFalse(TapTargetGeometry.centreIsAboveScreen(element(ref: 1, y: -10), screen: screen), "中心(y=10)は画面の中")
        XCTAssertFalse(TapTargetGeometry.centreIsAboveScreen(element(ref: 1, y: -3000, height: 5000), screen: screen),
                       "画面より背の高い要素は中心で言わない")
    }

    func testRefTapAboveTheScreenIsRefusedBeforeFiring() async {
        let driver = FakeDriver()
        driver.foregroundBundleID = "com.example.app"
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app", screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: [element(ref: 1, y: -100, id: "top_row"), element(ref: 2, y: 100, id: "ok_row")], truncatedCount: 0)
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        _ = try? await server.call(tool: "ft_snapshot", args: [:])
        do {
            _ = try await server.call(tool: "ft_tap", args: ["ref": 1])
            XCTFail("画面の上の外の要素を撃った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("above the top of the screen"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("Nothing was sent"), error.localizedDescription)
        }
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("tap(") }, "\(driver.calls)")
        // 逆向き: 画面の中の要素は撃つ
        _ = try? await server.call(tool: "ft_tap", args: ["ref": 2])
        XCTAssertTrue(driver.calls.contains { $0.hasPrefix("tap(") }, "\(driver.calls)")
    }

    func testGestureGuardAlsoRefusesAboveTheScreen() throws {
        let gestures = try source("Sources/fleetest-mcp/MCPServer+GesturesTools.swift")
        XCTAssertTrue(gestures.contains("Self.aboveScreenRefusal(element, screen: snapshot.screen"))
        let snapshot = try source("Sources/fleetest-mcp/MCPServer+Snapshot.swift")
        XCTAssertEqual(snapshot.components(separatedBy: "Self.aboveScreenRefusal(found, screen: fresh.screen").count - 1, 2,
                       "ghost と found の両方")
    }

    // MARK: - ft_batch の読み取りと注記

    func testBatchFinalReadsPayThePendingKeyboardAppearance() throws {
        let batch = try source("Sources/fleetest-mcp/MCPServer+Batch.swift")
        XCTAssertEqual(batch.components(separatedBy: "consumePendingTypeKeyboardCheck(").count - 1, 2,
                       "waitFor の読みと最後の読みの両方")
    }

    func testBatchCoordinateWarningReadsFreshAfterAnEarlierStep() async {
        let keyboardTree = SnapshotResponse(
            sessionBundleID: "com.example.app", screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: [element(ref: 1, y: 20, id: "field")], truncatedCount: 0,
            keyboardFrame: FTRect(x: 0, y: 500, width: 390, height: 344))
        let driver = FakeDriver()
        driver.snapshotResponse = keyboardTree
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        // 直近の木にはキーボードが無い(バッチの前の木)
        var stale = keyboardTree
        stale.keyboardFrame = nil
        server.lastSnapshots[MCPServer.sessionKey([:])] = stale
        var step = FlowStep(action: "tap")
        step.x = 100; step.y = 600
        let silent = await server.batchKeyboardCoordinateWarning(step, driver: driver, args: [:], actedEarlierInBatch: false)
        XCTAssertEqual(silent, "", "前の手が無いなら従来どおり直近の木で言う")
        let warned = await server.batchKeyboardCoordinateWarning(step, driver: driver, args: [:], actedEarlierInBatch: true)
        XCTAssertTrue(warned.contains("inside the soft keyboard"), warned)
    }

    func testFlatScreenNoteRunsAfterALaunchWithoutABaseline() throws {
        let batch = try source("Sources/fleetest-mcp/MCPServer+Batch.swift")
        XCTAssertTrue(batch.contains("guard tapsUnchanged || treeUnchanged || launchedInBatch else"))
        XCTAssertEqual(batch.components(separatedBy: "launchedInBatch: args[\"launch\"] != nil").count - 1, 2)
    }

    // MARK: - PIN ロック

    func testMCPNeverRetriesTheUnlockWaitAfterGivingUp() throws {
        let driver = try source("Sources/fleetest-mcp/MCPServer+Driver.swift")
        XCTAssertEqual(driver.components(separatedBy: "log: log, retriesAfterGivingUp: false").count - 1, 2)
        XCTAssertTrue(driver.contains("pendingWarnings[key, default: []].append(line)"),
                      "解除できなかった旨を応答の警告へ載せる")
        let device = try source("Sources/FTAndroid/AndroidPhysicalDevice.swift")
        XCTAssertTrue(device.contains("(!retriesAfterGivingUp && gaveUpAt != nil)"))
    }
}
