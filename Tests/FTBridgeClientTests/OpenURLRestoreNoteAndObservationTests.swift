// OI-177 ③: 同意の確かめの後の張り戻しの失敗を WebViewDelegatingDriver が写す(確かめが走った回だけ)。
// OI-186 ②: back() の前後の観測は委譲の待ちを払わない同じ経路(primary の生の木)で読む。

import XCTest
@testable import FTBridgeClient
import FTCore

private final class StubDriver: AppDriver, @unchecked Sendable {
    var trees: [SnapshotResponse]
    var note: String?
    var noteSetByConsent: String?
    /// false = 確かめが注記を触らないドライバ(入口で消さない実装)。前の操作の注記がそのまま残る
    var consentTouchesNote = true
    private(set) var snapshotCount = 0
    init(trees: [SnapshotResponse] = [], note: String? = nil) { self.trees = trees; self.note = note }
    var lastActionNote: String? { note }
    func acknowledgeOpenURLConsentIfPresent(bundleID: String, url: String) async {
        if consentTouchesNote { note = noteSetByConsent }
    }
    func openURL(_ url: String, bundleID: String?) async throws {}
    func snapshot() async throws -> SnapshotResponse {
        snapshotCount += 1
        return trees[min(snapshotCount - 1, trees.count - 1)]
    }
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "stub", osVersion: "", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws -> String? { nil }
    func uninstall(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { false }
    func launch(bundleID: String) async throws {}
    func terminate() async throws {}
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func screenshot() async throws -> Data { Data() }
}

private func webViewOnlyTree() -> SnapshotResponse {
    SnapshotResponse(sessionBundleID: "app", screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                     elements: [ElementInfo(ref: 1, type: "webView", identifier: "wv", label: nil, value: nil,
                                            placeholder: nil, enabled: true,
                                            frame: FTRect(x: 0, y: 0, width: 400, height: 800), depth: 0)],
                     truncatedCount: 0)
}

final class OpenURLRestoreNoteAndObservationTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testRestoreFailureNoteIsCopiedWhenTheCheckRan() async throws {
        let delegated = StubDriver()
        delegated.noteSetByConsent = StepNote.openURLSessionNotRestoredPrefix + "app after checking (500)"
        let driver = WebViewDelegatingDriver(primary: StubDriver(), delegated: delegated)
        try await driver.openURL("https://example.com", bundleID: "app")
        XCTAssertEqual(driver.lastActionNote, delegated.noteSetByConsent)
    }

    /// 確かめが走らなかった(入口で消えて何も立てない)回は、delegated に残る前の操作の注記を写さない
    func testStaleNoteOfAPreviousOperationIsNotCopied() async throws {
        let delegated = StubDriver(note: "a previous tap's note")
        delegated.consentTouchesNote = false
        let driver = WebViewDelegatingDriver(primary: StubDriver(), delegated: delegated)
        try await driver.openURL("https://example.com", bundleID: "app")
        XCTAssertNil(driver.lastActionNote)
    }

    /// BridgeClient が入口で注記を消すこと(走らなかった回に前回の張り戻しの失敗が残らない)と、共有の接頭辞で組むこと
    func testBridgeClientClearsTheNoteAtEntryAndUsesTheSharedPrefix() throws {
        let src = try source("Sources/FTBridgeClient/BridgeClient.swift")
        let entry = try XCTUnwrap(src.range(of: "func acknowledgeOpenURLConsent(bundleID: String, target: String, url: String) async {"))
        let guardRange = try XCTUnwrap(src.range(of: "guard !OpenURLConsentAttemptCache.shared.hasAttempted(key)"))
        let between = String(src[entry.upperBound..<guardRange.lowerBound])
        XCTAssertTrue(between.contains("lastActionNote = nil"), "入口で消していない")
        XCTAssertTrue(src.contains("StepNote.openURLSessionNotRestoredPrefix"))
    }

    func testObservationSnapshotDoesNotWaitOrDelegate() async throws {
        let primary = StubDriver(trees: [webViewOnlyTree()])
        let delegated = StubDriver(trees: [webViewOnlyTree()])
        let driver = WebViewDelegatingDriver(primary: primary, delegated: delegated)
        let start = ContinuousClock.now
        let tree = try await driver.observationSnapshot()
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1), "委譲の待ち(最大 5 秒)を払っている")
        XCTAssertEqual(delegated.snapshotCount, 0)
        XCTAssertEqual(primary.snapshotCount, 1)
        XCTAssertNil(tree.webViewPath)
    }

    /// ラッパーは observationSnapshot を転送する(既定実装に落ちると委譲の木を読んでしまう)
    func testWrappersForwardObservationSnapshot() throws {
        for path in ["Sources/FTCore/ActionCountingDriver.swift", "Sources/FTBridgeClient/HybridFallbackDriver.swift",
                     "Sources/FTBridgeClient/SessionRecoveryDriver.swift", "Sources/FTBridgeClient/FastLaunchDriver.swift",
                     "Sources/FTBridgeClient/LaunchPreflightDriver.swift", "Sources/FTBridgeClient/WebViewDelegatingDriver.swift"] {
            XCTAssertTrue(try source(path).contains("func observationSnapshot() async throws -> SnapshotResponse"), path)
        }
    }

    func testBackReadsBeforeAndAfterThroughObservationSnapshot() throws {
        let src = try source("Sources/FTDSL/CommandsAppControl.swift")
        XCTAssertTrue(src.contains("let before = try? await observer.observationSnapshot()"))
        XCTAssertTrue(src.contains("let after = try? await observer.observationSnapshot()"))
    }
}
