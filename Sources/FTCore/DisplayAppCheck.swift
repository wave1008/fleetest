// DisplayAppCheck.swift
// 端末の表示条件(外観・文字サイズ)が**アプリに実際に届いたか**の確かめ(純粋な判定と受け渡し)。
// 設定の読み返しは端末の設定値しか見ないので、Simulator の SpringBoard が変更を届けない状態では変わっていない外観を「設定できた」と記録する。
// 申告元は in-app ブリッジの `/status`(`screenAppearance` / `contentSizeCategory`)。確かめるのはシナリオの子(CommandsDisplay.swift)、
// 届かなかった端末の回復は親(`DisplayRecoveryRequests` → ProfileWorkerFactory.clearResidualSystemAlert)。
import Foundation

extension FTTextSize {
    /// in-app の `UIApplication.preferredContentSizeCategory.rawValue`(`iosStep` と同じ段階)
    var uiContentSizeCategory: String {
        switch self {
        case .small: return "UICTContentSizeCategoryS"
        case .default: return "UICTContentSizeCategoryL"
        case .large: return "UICTContentSizeCategoryXL"
        case .extraLarge: return "UICTContentSizeCategoryXXXL"
        case .accessibility: return "UICTContentSizeCategoryAccessibilityL"
        }
    }
}

extension DisplaySettingsLimits {
    /// 設定が in-app のアプリへ届くのを待つ上限[秒]。根拠: 健全な Simulator では設定から約 2 秒以内に届いた(実測)の約 2.5 倍。
    /// 尽きたらそのステップを失敗(`display-not-applied`)にする
    public static let appPropagationSeconds: TimeInterval = 5
    /// 届いたかの読み直しの間隔[秒]。/status は軽い問い合わせ(1往復)
    public static let appPropagationPollSeconds: TimeInterval = 0.25
}

/// in-app ブリッジが申告した、アプリが今受け取っている表示条件。nil の欄 = 読んでいない(判定しない)
public struct InAppDisplayReport: Equatable, Sendable {
    public var screenAppearance: String?
    public var contentSizeCategory: String?
    public init(screenAppearance: String?, contentSizeCategory: String?) {
        self.screenAppearance = screenAppearance
        self.contentSizeCategory = contentSizeCategory
    }
    public var isEmpty: Bool { screenAppearance == nil && contentSizeCategory == nil }
}

/// 子が確かめる期待。nil のキーは確かめない。親から `--display-expected` で渡し、DSL の `setAppearance` / `setTextSize` で更新する
public struct DisplayAppExpectation: Equatable, Sendable {
    public var appearance: FTAppearance?
    public var textSize: FTTextSize?
    public init(appearance: FTAppearance? = nil, textSize: FTTextSize? = nil) {
        self.appearance = appearance
        self.textSize = textSize
    }

    /// `appearance=light,textSize=default`(確かめないキーは省く)。空なら nil
    public var argument: String? {
        var parts: [String] = []
        if let appearance { parts.append("appearance=\(appearance.rawValue)") }
        if let textSize { parts.append("textSize=\(textSize.rawValue)") }
        return parts.isEmpty ? nil : parts.joined(separator: ",")
    }

    /// 親が確かめられるキー(= 開始時に合わせた/合わせようとしたキー)だけを渡す
    public init(expected: DisplayExpectation, handled: Set<DisplayKey>) {
        self.init(appearance: handled.contains(.appearance) ? expected.appearance : nil,
                  textSize: handled.contains(.textSize) ? expected.textSize : nil)
    }

    public static func parse(_ raw: String) -> DisplayAppExpectation? {
        var result = DisplayAppExpectation()
        for part in raw.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return nil }
            switch pair[0] {
            case "appearance":
                guard let value = FTAppearance.parse(pair[1]) else { return nil }
                result.appearance = value
            case "textSize":
                guard let value = FTTextSize.parse(pair[1]) else { return nil }
                result.textSize = value
            default: return nil
            }
        }
        return result
    }
}

public enum DisplayAppCheck {
    /// 期待と申告が食い違うキー(`key: 期待 vs 申告` の文)。**申告が無い欄は判定しない**(旧ブリッジ・XCUITest・読めなかった)
    public static func mismatches(expected: DisplayAppExpectation, report: InAppDisplayReport) -> [String] {
        var result: [String] = []
        if let want = expected.appearance, let got = report.screenAppearance, got != want.rawValue {
            result.append("appearance: expected \(want.rawValue), the app reports \(got)")
        }
        if let want = expected.textSize, let got = report.contentSizeCategory, got != want.uiContentSizeCategory {
            result.append("textSize: expected \(want.rawValue) (\(want.uiContentSizeCategory)), the app reports \(got)")
        }
        return result
    }

    /// 失敗の文(事実だけ)。尽きるまで待った秒数を添える
    public static func failureDetail(mismatches: [String], waitedSeconds: TimeInterval) -> String {
        "the device's display settings did not reach the app within \(String(format: "%g", waitedSeconds))s: "
            + mismatches.joined(separator: "; ")
            + ". The simulator's SpringBoard may have stopped delivering display changes to apps"
            + " (it is restarted before the next scenario)"
    }
}

/// 申告の注入口(陽性対照用)。**観測の経路だけに効かせる** —— 申告を差し替えるだけでデバイスは触らない。
/// 例: `FT_FAKE_APP_DISPLAY=appearance=light`(アプリがいつもライトと申告する)。書式は `DisplayAppExpectation` と同じ
public enum DisplayAppInjection {
    public static let environmentKey = "FT_FAKE_APP_DISPLAY"
    /// 注入したときの回復も実際に撃つ明示の許可(既定は撃たない = 注入ではデバイスを触る回復を撃たない)
    public static let recoveryEnvironmentKey = "FT_FAKE_APP_DISPLAY_RECOVERY"

    public static func isActive(environment: [String: String]) -> Bool {
        environment[environmentKey].flatMap(DisplayAppExpectation.parse) != nil
    }

    public static func recoveryAllowed(environment: [String: String]) -> Bool {
        !isActive(environment: environment) || environment[recoveryEnvironmentKey] == "on"
    }

    public static func apply(to report: InAppDisplayReport, environment: [String: String]) -> InAppDisplayReport {
        guard let raw = environment[environmentKey], let fake = DisplayAppExpectation.parse(raw) else { return report }
        var result = report
        if let appearance = fake.appearance { result.screenAppearance = appearance.rawValue }
        if let size = fake.textSize { result.contentSizeCategory = size.uiContentSizeCategory }
        return result
    }
}

/// 「アプリへ届かなかった」シナリオの後に、次のシナリオの前で Simulator を回復する要求(レーンの label 単位)。
/// 入れるのは `RunOrchestrator`(失敗ステップの種類を見た所)・取り出すのは `ProfileWorkerFactory.clearResidualSystemAlert`
public final class DisplayRecoveryRequests: Sendable {
    public static let shared = DisplayRecoveryRequests()
    private let labels = LockedValue<Set<String>>([])
    public init() {}
    public func request(label: String) { labels.withLock { _ = $0.insert(label) } }
    public func take(label: String) -> Bool { labels.withLock { $0.remove(label) != nil } }

    public static func restartedMessage(label: String, seconds: Double) -> String {
        "🧹 \(label): the previous scenario's display settings did not reach the app — restarted SpringBoard"
            + " and rebuilt the bridge (\(String(format: "%.1f", seconds))s)"
    }

    public static func failedMessage(label: String, reason: String) -> String {
        "⚠️ \(label): the previous scenario's display settings did not reach the app, and the simulator could not be"
            + " restored: \(reason)"
    }

    public static func injectedNotRestartedMessage(label: String) -> String {
        "⚠️ \(label): display settings did not reach the app (injected by \(DisplayAppInjection.environmentKey));"
            + " not restarting SpringBoard (set \(DisplayAppInjection.recoveryEnvironmentKey)=on to restart it)"
    }
}
