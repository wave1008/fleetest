// iOS の要素の「描画の出どころ」を、XCTest の非公開属性で取った本当のクラス名と祖先から決める(純粋関数)。
// XCUITest ランナー(Runner/FleetestRunnerUITests)が単体でコンパイルして使う = Foundation だけに依存し、
// FTCore の他の型を参照しない。BridgeSourceSet.xcuitest と xcproj の FTCore グループの両方に載っている
// (触ったらブリッジの版を上げる)。目印の表の根拠は docs の FD-0.1 / DR-230。

import Foundation

public enum IOSRendererMarkers {

    /// 1ノード分の目印。当たらなければ nil。同じノードでは上から順に見て最初に当たったものが勝つ
    public static func marker(className: String, viewControllerClassName: String?) -> String? {
        let vc = viewControllerClassName ?? ""
        if className == "WebAccessibilityObjectWrapper" || className.hasPrefix("WK") { return "web" }
        if className.contains("KBKey") || className.hasPrefix("UIKeyboard") || className.hasPrefix("UIRemoteKeyboard")
            || className.hasPrefix("_UIRemoteKeyboard") { return "keyboard" }
        if className.hasPrefix("Flutter") || className == "SemanticsObjectContainer" || vc == "FlutterViewController" {
            return "flutter"
        }
        if className.contains("androidx.compose") || vc == "ComposeHostingViewController" { return "compose" }
        if className.hasPrefix("RCT") || className.hasPrefix("RNC") || className.hasPrefix("RNS") { return "reactNative" }
        if className == "SwiftUI.AccessibilityNode"
            || (className.contains("SwiftUI") && className.contains("Hosting") && !className.contains("PlatformViewHost")) {
            return "swiftUI"
        }
        if className.contains("PlatformViewHost") { return "uikit" }
        return nil
    }

    /// chain[0] = 要素本人、以降が祖先(近い順)。最も近い目印が勝つ(SwiftUI の中の Compose は compose)。
    /// どこにも目印が無いときは要素本人の公開クラス(`elementBaseType`)で決める:
    /// UIView 系なら "uikit"、`UIAccessibilityElement` / `NSObject` / `UIResponder` なら UIKit の自前の要素 = "uikitCustom"、
    /// 取れていなければ nil(不明)。戻り値: flutter / compose / reactNative / swiftUI / uikit / keyboard / web / uikitCustom
    public static func renderer(chain: [(className: String, viewControllerClassName: String?)],
                                elementBaseType: String?) -> String? {
        for node in chain {
            if let hit = marker(className: node.className, viewControllerClassName: node.viewControllerClassName) {
                return hit
            }
        }
        guard let base = elementBaseType, !base.isEmpty else { return nil }
        if base == "UIAccessibilityElement" || base == "NSObject" || base == "UIResponder" { return "uikitCustom" }
        return "uikit"
    }
}
