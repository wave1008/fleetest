// 対象アプリ(実行プロファイルのアプリ)をこのシナリオで起こしたか・止めたかの**唯一の持ち主**。StepExecutor が持ち、DSL(FTDriveCore)が
// 書き、両方が読む。写しを置かない(DSL と StepExecutor に別々に持っていた頃、照会で「居る」と分かったときに片方だけが起動済みへ戻った)。
// 「止めた後に起こしうる操作で解ける印」(FTDriveCore の appStoppedByScenario)とは意味が違うので統合しない

import Foundation

/// **起動の手でだけ `.launched` へ戻る**(間に別のステップが通っても `.stoppedByScenario` のまま)。読み手:
/// back() / activate の「止めたアプリを起こさない」照会を止めた後だけに限る・失敗の時点にプロセスが居なかった事実を
/// `appCrash`(processGone)に記録するのを `.launched`(起こして、その後このシナリオが止めていない)のときだけに限る・
/// Android の止めたアプリへの読み・送りの断り。openURL の注入付きの起こし直し等、DSL が知らない起動では戻らない = 記録しない側に倒れる
public enum AppUnderTestLife: Sendable, Equatable { case notLaunched, launched, stoppedByScenario }

public final class AppUnderTestLifeRecord: Sendable {
    // 止めたコマンド名は `.stoppedByScenario` のときだけ意味を持つ(再び動かす手順の案内が removeApp だけ違う = StoppedAppAdvice)
    private let state = LockedValue<(life: AppUnderTestLife, stoppedCommand: String?)>((.notLaunched, nil))
    public init() {}

    public var life: AppUnderTestLife { state.withLock { $0.life } }
    /// 止めたままなら止めたコマンド名(`terminateApp` / `removeApp` / `clearAppData`)。それ以外は nil
    public var stoppedCommand: String? { state.withLock { $0.life == .stoppedByScenario ? $0.stoppedCommand : nil } }
    public var isStopped: Bool { life == .stoppedByScenario }

    public func noteStopped(by command: String) { state.withLock { $0 = (.stoppedByScenario, command) } }
    /// 起動の手(launchApp / restartApp / tapAppIcon)が対象アプリを起こした
    public func noteLaunched() { state.withLock { $0 = (.launched, nil) } }
    /// 止めた後に照会が「居る」と答えた(DSL の知らない起動)。止めたままのときだけ起動済みへ戻す
    public func noteFoundRunning() {
        state.withLock { if $0.life == .stoppedByScenario { $0 = (.launched, nil) } }
    }
}
