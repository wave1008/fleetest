// BridgeLiveness.swift
// 失敗後のブリッジ生存プローブ(観察窓・ログ静止の刻み・判定)。オーケストレーション全体は RunOrchestrator.swift

import Foundation

/// 失敗後ブリッジチェックの観察窓と、ログ静止によるウェッジ確定時間(秒)。
/// AX 飽和(健全だが数十秒無応答)を「接続不能」と誤検知しないための値(bridgeUnreachable 参照)
let BRIDGE_PROBE_OBSERVE_SECONDS: TimeInterval = 60
let BRIDGE_PROBE_LOG_SILENCE_SECONDS: TimeInterval = BridgeLivenessBudget.logSilenceSeconds

/// ブリッジ(XCUITest ランナー)の「ログが静止したらウェッジ」の刻み。bridgeUnreachable(失敗後の
/// 再プローブ)と BridgeProvisioner(起動中と名乗る古い pid の引き取り)が同じ値を使う ——
/// 別々に持つと同じランナーを片方は健全・片方はウェッジと読む
public enum BridgeLivenessBudget {
    /// /status 無応答のままランナーログが伸びない時間(秒)。AX 処理中のランナーは数秒おきに
    /// ログへ書くので、15 秒の完全な静止は処理中ではなくウェッジの印(実測系列は bridgeUnreachable の doc)
    public static let logSilenceSeconds: TimeInterval = 15
}

/// 失敗後ブリッジプローブ 1 回分の結果(probeBridge 注入クロージャの戻り値)
public enum BridgeProbeOutcome: Sendable {
    case ok
    /// connection refused = ポート LISTEN なし(ブリッジプロセス死亡)
    case refused
    /// 期限内無応答(busy かウェッジかはこれだけでは未確定)
    case silent
    /// 応答はあるが**別のデバイスのブリッジ**が答えた(同じポートを別のデバイスが奪った。
    /// 同じ bundle ID のアプリが載っていると /status 以外では見分けられない = 放置すると
    /// このレーンのシナリオが別のデバイスで緑になる)。detail は BridgeIdentityCheck の文言
    case hijacked(detail: String)

    /// `.refused` を「ブリッジプロセス死亡」と即断してよい宛先か。ループバック(シミュレータ・
    /// USB トンネル)は LISTEN 不在の証拠になるが、**LAN の実機は Wi-Fi の瞬断・省電力でも
    /// 接続不能(-1004)を返す** —— 即断すると生きたランナーを cleanupRetiredWorker が SIGTERM する
    /// (実測: 外からの /status が失敗の 1 秒前も 6 秒後も応答していたのに、4 run で 12 回離脱)。
    /// false の宛先では `.silent` と同じく観察窓とランナーログの成長で判定する
    public static func refusalIsConclusive(host: String?) -> Bool {
        guard let host else { return true }
        return ["127.0.0.1", "localhost", "::1"].contains(host)
    }
}

/// 失敗後のブリッジ生存判定(`bridgeUnreachable` の 1 周分)。**純粋関数**(`decide`)に切り出して
/// 単体テストで固める。観察の材料は3つ —— /status の応答・ホスト側のランナープロセスの生死・
/// ランナーログの成長。
public enum BridgeLiveness {
    /// 離脱理由に写す事実(推測は書かない)。`nil` の材料には触れない
    public enum Verdict: Sendable, Equatable {
        /// 応答した = 生きている(busy でもここへ来る)
        case reachable
        /// 接続不能を確定。detail は run.json の離脱理由に入る事実
        case unreachable(detail: String?)
        /// まだ決めない(観察を続ける)
        case keepObserving
    }

    /// - runnerProcessAlive: ホスト側のランナープロセス(xcuitest の xcodebuild)の生死。
    ///   **`nil` は「分からない」**(in-app ブリッジのようにホスト側のプロセスが無い形)。
    /// - logSilentSeconds: ランナーログが最後に伸びてからの秒数(ログが無ければ nil)。
    /// - windowExpired: 観察窓(`BRIDGE_PROBE_OBSERVE_SECONDS`)を使い切ったか。
    ///
    /// **プロセスが生きている間はログ静止の近道を使わない** —— XCUITest の 1 照会は、対象アプリが
    /// 外部要因で背面に回ると実測 31 秒ブロックし(実機で外から設定アプリを前面にした)、
    /// その間ログも /status も止まる。近道(15 秒)で確定すると、**生きているランナーを止めて起動し直す**。
    /// 逆にプロセスが消えていれば、それが最も確かな死の証拠なので窓の残りを待たない。
    public static func decide(probe: BridgeProbeOutcome, host: String?, runnerProcessAlive: Bool?,
                             logSilentSeconds: TimeInterval?, logSilenceThreshold: TimeInterval,
                             windowExpired: Bool) -> Verdict {
        switch probe {
        case .ok:
            return .reachable
        case .hijacked(let detail):
            return .unreachable(detail: detail)
        case .refused:
            if BridgeProbeOutcome.refusalIsConclusive(host: host) {
                return .unreachable(detail: "nothing is listening on its port")
            }
        case .silent:
            break
        }
        if runnerProcessAlive == false {
            return .unreachable(detail: "its runner process is gone")
        }
        let logSilent = logSilentSeconds.map { $0 >= logSilenceThreshold }
        if runnerProcessAlive != true, logSilent == true {
            return .unreachable(detail: "its runner log stopped growing")
        }
        guard windowExpired else { return .keepObserving }
        // 窓を使い切った。ログが直近まで伸びていれば busy(健全)側に倒す(既存の規律)
        if logSilent == false { return .reachable }
        return .unreachable(detail: runnerProcessAlive == true
            ? "its runner process was still alive but did not answer /status during the observation window"
            : nil)
    }
}
