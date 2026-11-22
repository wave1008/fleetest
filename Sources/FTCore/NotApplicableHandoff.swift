// 対象外(`ScenarioEvent.notApplicableReason`)で終わったシナリオを、同じ run の同じ OS のまだ試していない台へ回し直すかの判定(DR-214)。
// 機械の中(`ScenarioQueue` = 鍵はレーン名)と機械をまたぐ run(`DynamicDispatcher` = 鍵はエントリ番号)が**同じ関数**を通る。
// 呼び手は鍵の型を問わず文字列で渡す。

import Foundation

public enum NotApplicableHandoff {
    public enum Verdict: Equatable, Sendable {
        /// まだ試していない生きた台がある。結果は確定させず回し直す
        case handOn
        /// 全部の台が試して対象外・または最初から他の台が居ない。対象外(緑)で確定する(従来どおり)
        case skipped
        /// 試していない台が run から落ちて、回し直す先が残らない。失敗(実行しなかった)で確定する
        case notRun

        /// 親子のワイヤ(`WorkQueueProtocol.Reply.verdict`)の綴り
        public var wire: String {
            switch self {
            case .handOn: return "hand"
            case .skipped: return "skip"
            case .notRun: return "fail"
            }
        }

        public init?(wire: String) {
            switch wire {
            case "hand": self = .handOn
            case "skip": self = .skipped
            case "fail": self = .notRun
            default: return nil
            }
        }
    }

    /// - tried: このシナリオを試して対象外と宣言した台(今回の台を含む)
    /// - live: いま run に居る同じ OS の台(試した台を含んでよい)
    /// - departed: run から落ちた(供給で合流できなかった・離脱した・終わった)同じ OS の台
    /// 判定の順序に意味がある: 生きた未試行の台 > 落ちた未試行の台 > どちらも無い。
    public static func decide(tried: Set<String>, live: Set<String>, departed: Set<String>) -> Verdict {
        if !live.subtracting(tried).isEmpty { return .handOn }
        if !departed.subtracting(tried).isEmpty { return .notRun }
        return .skipped
    }

    /// 全部の子が終わった後の、対象外の記帳がある配れなかった単位の判定。
    /// - tried: 試して対象外と宣言した台(空なら対象外の確定ではない = `.notRun`)
    /// - untriedNeverLaunched: 未試行で、この対象の子を一度も起動しなかった台(合流しなかったマシン。数えない)
    /// - untriedLaunched: 未試行で、子を起動した(参加した)後に離脱・合流できなかった台(子の中の離脱の申告を含む)
    /// `.skipped` = 対象外で確定(緑)・`.notRun` = 従来どおり「配れなかった」失敗
    public static func decideAtEnd(tried: Set<String>, untriedNeverLaunched: Set<String>,
                                   untriedLaunched: Set<String>) -> Verdict {
        _ = untriedNeverLaunched
        if tried.isEmpty || !untriedLaunched.isEmpty { return .notRun }
        return .skipped
    }

    /// `.notRun` の失敗の理由(結果 JSON の `failedSteps` と run ログに出る)。`declared` = 対象外の宣言の理由
    public static func notRunReason(declared: String) -> String {
        "not run: the devices that had not tried it dropped out of the run"
            + " (every device that tried it declared it not applicable: \(declared))"
    }

    /// 回し直した結果の捨て理由(`resultDiscardedReason`)
    public static func discardedReason(declared: String, device: String, handedOn: Bool) -> String {
        "not applicable on \(device) (\(declared)); "
            + (handedOn ? "handed to a device that has not tried it" : "no device that has not tried it is left")
    }
}
