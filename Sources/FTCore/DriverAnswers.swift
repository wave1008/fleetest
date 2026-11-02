// 構成ごとに「どの観測に答えられるか」の唯一の表(AppDriver の観測4つ = `Probe` を返す要件)。
// 本物の葉のドライバが表どおりに実装していることは `DriverAnswersConformanceTests` がソース走査で縛り、
// テストの偽ドライバはこの表で答え方を決める(本物の答えない観測に偽物が値を返すと、本番で届かない判定が緑になる)。

import Foundation

public struct DriverAnswers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let foregroundAppID = DriverAnswers(rawValue: 1 << 0)
    public static let keyguardShowing = DriverAnswers(rawValue: 1 << 1)
    public static let systemAlert = DriverAnswers(rawValue: 1 << 2)
    public static let systemUICovering = DriverAnswers(rawValue: 1 << 3)
    public static let systemUIHoldsInputFocus = DriverAnswers(rawValue: 1 << 4)

    /// XCUITest ブリッジ(BridgeClient)。前面のアプリ名は XCUITest に問う口が無い
    public static let iosXCUITest: DriverAnswers = [.systemAlert, .systemUICovering]
    /// inapp-boost モード: 包む相手を2つ持つドライバ(ライブ操作の HybridFallbackDriver・シナリオ実行の WebViewDelegatingDriver)が
    /// アラートと覆いを XCUITest ブリッジへ回す(in-app へ回すと常に `.notAnswerable`。回し先は DriverAnswersConformanceTests が縛る)
    public static let iosInAppBoost: DriverAnswers = [.systemAlert, .systemUICovering]
    /// in-app ブリッジ単体(InAppDriver)。自プロセスの外は見えない
    public static let iosInApp: DriverAnswers = []
    /// Android は木の根が active window なのでアラート・覆いの照会は要らない(木に出る)
    public static let android: DriverAnswers = [.foregroundAppID, .keyguardShowing, .systemUIHoldsInputFocus]
}
