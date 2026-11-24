// iOS の要素の描画の出どころ(`IOSRendererMarkers`)。表の根拠は調査の README(iOS の規則)。
// ランナーが単体でコンパイルする純粋関数なので、ここで表を固定する

import XCTest
@testable import FTCore

final class IOSRendererMarkersTests: XCTestCase {

    private func renderer(_ chain: [(String, String?)], base: String? = nil) -> String? {
        IOSRendererMarkers.renderer(chain: chain.map { (className: $0.0, viewControllerClassName: $0.1) },
                                    elementBaseType: base)
    }

    func testFlutterChain() {
        XCTAssertEqual(renderer([("FlutterSemanticsObject", nil), ("SemanticsObjectContainer", nil), ("FlutterView", "FlutterViewController")],
                                base: "UIAccessibilityElement"), "flutter")
        XCTAssertEqual(renderer([("UIView", "FlutterViewController")]), "flutter")
    }

    func testNearestMarkerWinsComposeInsideSwiftUIHosting() {
        XCTAssertEqual(renderer([("androidx.compose.ui.Node", nil), ("_TtGC7SwiftUI14_UIHostingViewV", nil)]), "compose")
        XCTAssertEqual(renderer([("UIView", "ComposeHostingViewController")]), "compose")
    }

    func testReactNative() {
        XCTAssertEqual(renderer([("RCTViewComponentView", nil), ("RCTSurfaceView", nil)], base: "UIView"), "reactNative")
        XCTAssertEqual(renderer([("RNCSafeAreaView", nil)]), "reactNative")
        XCTAssertEqual(renderer([("RNSScreen", nil)]), "reactNative")
    }

    func testSwiftUI() {
        XCTAssertEqual(renderer([("SwiftUI.AccessibilityNode", nil)], base: "NSObject"), "swiftUI")
        XCTAssertEqual(renderer([("UIView", nil), ("_TtGC7SwiftUI14_UIHostingViewV", nil)]), "swiftUI",
                       "Hosting を含む SwiftUI の土台は SwiftUI")
    }

    func testUIKitInsideSwiftUIPlatformViewHost() {
        XCTAssertEqual(renderer([("UIButton", nil), ("SwiftUI.PlatformViewHost<UIKitView>", nil), ("_TtGC7SwiftUI14_UIHostingViewV", nil)]), "uikit",
                       "PlatformViewHost は SwiftUI の Hosting 判定より先に uikit")
    }

    func testKeyboardKeyOverAFlutterAppIsTheKeyboard() {
        XCTAssertEqual(renderer([("UIAccessibilityElementKBKey", nil), ("UIKeyboardLayoutStar", nil), ("FlutterView", "FlutterViewController")],
                                base: "UIAccessibilityElement"), "keyboard")
        XCTAssertEqual(renderer([("UIRemoteKeyboardWindow", nil)]), "keyboard")
        XCTAssertEqual(renderer([("_UIRemoteKeyboardPlaceholderView", nil)]), "keyboard")
    }

    func testWebInsideFlutterIsWeb() {
        XCTAssertEqual(renderer([("WebAccessibilityObjectWrapper", nil), ("WKContentView", nil), ("FlutterView", "FlutterViewController")]), "web")
        XCTAssertEqual(renderer([("WKWebView", nil)]), "web")
    }

    func testUIKitsOwnAccessibilityElementWithoutAMarkerIsCustom() {
        XCTAssertEqual(renderer([("VKPointFeatureAccessibilityElement", nil), ("VKMapView", nil)], base: "UIAccessibilityElement"), "uikitCustom")
        XCTAssertEqual(renderer([("MobileCalHourAccessibilityElement", nil)], base: "NSObject"), "uikitCustom")
        XCTAssertEqual(renderer([("SomeResponder", nil)], base: "UIResponder"), "uikitCustom")
    }

    func testPlainViewsAreUIKit() {
        XCTAssertEqual(renderer([("UIButton", nil), ("UIView", nil)], base: "UIButton"), "uikit")
        XCTAssertEqual(renderer([("UITableViewCell", nil)], base: "UIView"), "uikit")
    }

    func testUnknownBaseTypeIsUnknown() {
        XCTAssertNil(renderer([("Whatever", nil)], base: nil))
        XCTAssertNil(renderer([("Whatever", nil)], base: ""))
        XCTAssertNil(renderer([], base: nil))
    }

    func testMarkersAreCheckedInTheDocumentedOrderWithinOneNode() {
        // web が keyboard・flutter より先
        XCTAssertEqual(IOSRendererMarkers.marker(className: "WKKBKey", viewControllerClassName: "FlutterViewController"), "web")
        // キーボードが flutter より先
        XCTAssertEqual(IOSRendererMarkers.marker(className: "UIKeyboardX", viewControllerClassName: "FlutterViewController"), "keyboard")
        XCTAssertNil(IOSRendererMarkers.marker(className: "UIView", viewControllerClassName: "UIViewController"))
    }
}
