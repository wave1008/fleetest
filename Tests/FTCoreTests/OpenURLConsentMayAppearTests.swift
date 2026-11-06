import XCTest
@testable import FTCore

/// 同意のアラートは開いた先がこのアプリ(自分のスキーム)のときだけ出る(OI-179 ②: 別アプリ向けで毎回約 9 秒の空振り)
final class OpenURLConsentMayAppearTests: XCTestCase {
    func testOnlyOwnSchemesCanRaiseThisAppsConsent() {
        let own: Set<String> = ["fte2eflutter"]
        XCTAssertTrue(OpenURLConsent.mayAppear(url: "FTE2EFLUTTER://screen/x", ownSchemes: own), "大小を区別しない")
        XCTAssertFalse(OpenURLConsent.mayAppear(url: "https://example.com", ownSchemes: own))
        XCTAssertFalse(OpenURLConsent.mayAppear(url: "App-prefs:", ownSchemes: own))
        XCTAssertTrue(OpenURLConsent.mayAppear(url: "https://example.com", ownSchemes: nil), "スキームが分からないときは従来どおり試す")
        XCTAssertFalse(OpenURLConsent.mayAppear(url: "not a url", ownSchemes: nil))
    }
}
