// AppDriver.acknowledgeOpenURLConsentIfPresent の既定実装は no-op(ほとんどのドライバは正しく
// それでよい。InAppDriver は明示の no-op)。実装を持つべきなのは springboard を見られる接続の2箇所だけ:
//   - BridgeClient(XCUITest 接続)自身
//   - AppAttachDriver(WebViewDelegatingDriver.openURL が inapp-boost モードでここへ明示的に回す)
// AppAttachDriver は client: BridgeClient を private に包んで他の操作を1つずつ転送しており、
// この転送を消すと**コンパイルは通ったまま**既定の no-op(何もしない)に静かに落ちる
// (AppDriverDefaultDispatchTests が守るのは「宣言漏れ」で、この「個々の転送漏れ」は別物。
// OpenURLForwardingTests / SystemUIDriverHomeForwardingTests と同じ理由でソース走査にする)。

import XCTest

final class OpenURLConsentForwardingTests: XCTestCase {

    func testAppAttachDriverForwardsConsentToItsClient() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTBridgeClientTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
        let path = root.appendingPathComponent("Sources/FTBridgeClient/AppAttachDriver.swift")
        let source = try String(contentsOf: path, encoding: .utf8)

        XCTAssertTrue(source.contains("func acknowledgeOpenURLConsentIfPresent(bundleID: String, url: String) async"),
                      "AppAttachDriver が acknowledgeOpenURLConsentIfPresent を宣言していません"
                          + "(既定の no-op に落ちると inapp-boost モードの openURL 同意が springboard を見られる"
                          + "側でも常に空振りする)")
        XCTAssertTrue(source.contains("client.acknowledgeOpenURLConsentIfPresent(bundleID: bundleID, url: url)"),
                      "AppAttachDriver.acknowledgeOpenURLConsentIfPresent が client へ転送していません")
    }

    /// WebViewDelegatingDriver.openURL が delegated(XCUITest attach)側でも同意ステップを
    /// 明示的に試すこと。primary(in-app)だけに任せると springboard を見られず必ず空振りする
    func testWebViewDelegatingDriverAlsoTriesConsentOnTheDelegatedSide() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let path = root.appendingPathComponent("Sources/FTBridgeClient/WebViewDelegatingDriver.swift")
        let source = try String(contentsOf: path, encoding: .utf8)

        XCTAssertTrue(source.contains("delegated.acknowledgeOpenURLConsentIfPresent(bundleID: bundleID, url: url)"),
                      "WebViewDelegatingDriver.openURL が delegated 側で同意ステップを試していません")
    }

    /// **openURL を転送するラッパーは、同意ステップも転送しなければならない**。
    /// 既定実装が no-op(501 ではない)なので、転送を書き忘れても**コンパイルは通り、テストも緑のまま
    /// 黙って何もしない**(`DefaultImplementationForwardingTests` は 501 を投げる操作しか見ないため
    /// この穴を検出できない)。openURL を持つラッパーを列挙して両方の宣言を要求する
    func testEveryWrapperThatForwardsOpenURLAlsoForwardsConsent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dir = root.appendingPathComponent("Sources/FTBridgeClient")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var missing: [String] = []
        for file in files {
            let name = String(file.lastPathComponent.dropLast(".swift".count))
            // BridgeClient は転送元ではなく実装本体
            guard name != "BridgeClient" else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            guard source.contains("func openURL(_ url: String, bundleID: String?) async throws") else { continue }
            if !source.contains("func acknowledgeOpenURLConsentIfPresent(bundleID: String, url: String) async") {
                missing.append(name)
            }
        }
        XCTAssertEqual(missing, [],
                       "openURL を転送しているのに同意ステップを転送していないラッパーがあります。"
                           + "既定は no-op なので、書き忘れても黙って空振りします")
    }

    /// **in-app 接続は同意を確かめない**: 開いた先が前面になると対象アプリが一時停止し、in-app への `/session` が 409 ではなく
    /// 上限(45 秒)まで返らなかった(18周目 iultra F1: 最初の openURL が約 57 秒)。配送は `deliverURL`、同意の口は no-op
    func testInAppDriverNeverAsksItsConnectionForConsent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FTBridgeClient/InAppDriver.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("client.deliverURL(url)"), "InAppDriver.openURL が配送だけの口を使っていない")
        XCTAssertFalse(source.contains("client.openURL("), "InAppDriver が同意の確かめ付きの openURL を in-app 接続へ撃っている")
        XCTAssertFalse(source.contains("client.acknowledgeOpenURLConsentIfPresent("),
                       "InAppDriver が同意の確かめを in-app 接続へ撃っている")
    }

    /// 同意の確かめの後のセッションの向け直しは前面化しない(attach)。activate は開いた先のアプリ(Safari 等)を背面へ回して
    /// 対象アプリを前面へ引き戻し、openURL が ✅ のまま開いた先が消えていた(16周目 im4・iultra F1)
    func testConsentCheckPointsTheSessionBackWithoutBringingTheAppToFront() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FTBridgeClient/BridgeClient.swift"), encoding: .utf8)
        guard let start = source.range(of: "func acknowledgeOpenURLConsent(bundleID: String, target: String, url: String)"),
              let end = source.range(of: "public func acknowledgeOpenURLConsentIfPresent", range: start.upperBound..<source.endIndex)
        else { return XCTFail("走査の範囲が見つからない") }
        let body = String(source[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("try await attach(bundleID: bundleID)"), "向け直しが attach でない")
        XCTAssertFalse(body.contains("activate(bundleID"), "向け直しに activate を使っている(開いた先を背面へ回す)")
    }
}
