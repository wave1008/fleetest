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

    /// 試した台と同じ種類(観測した機種 × OS / イメージ)の台は試した扱いにするか(iOS Simulator・Android Emulator。DR-214)。
    /// - kinds: 鍵 → その鍵の台で観測した種類(まだ試していない側の見込み)。**不明(欄無し・空)は覆わない**
    /// - evidence: 試して対象外と答えた台で**実際に観測した**種類。証拠はこれだけ —— 鍵の種類から作らない
    ///   (親の鍵 = エントリは台の集まりで、子は一部の台しか使わないことがある = `ResolvedProfile.limitingDevices`)。
    ///   実行プロファイルの `model` は表示用で識別に使わない(折りたたみ機を取りこぼして誤った緑にするのを防ぐ)
    public static func covered(_ key: String, tried: Set<String>, kinds: [String: Set<String>], evidence: Set<String>) -> Bool {
        guard !tried.contains(key), let own = kinds[key], !own.isEmpty else { return false }
        return own.isSubset(of: evidence)
    }

    /// 試した台 + 試した台と同じ種類の台(`keys` の中から)
    public static func effectiveTried(tried: Set<String>, among keys: Set<String>, kinds: [String: Set<String>],
                                      evidence: Set<String>) -> Set<String> {
        tried.union(keys.filter { covered($0, tried: tried, kinds: kinds, evidence: evidence) })
    }

    /// - tried: このシナリオを試して対象外と宣言した台(今回の台を含む)
    /// - live: いま run に居る同じ OS の台(試した台を含んでよい)
    /// - departed: run から落ちた(供給で合流できなかった・離脱した・終わった)同じ OS の台
    /// - kinds / evidence: `covered`。渡せる情報が無い呼び手は [:] / []
    /// 判定の順序に意味がある: 生きた未試行の台 > 落ちた未試行の台 > どちらも無い。
    public static func decide(tried: Set<String>, live: Set<String>, departed: Set<String>,
                              kinds: [String: Set<String>], evidence: Set<String>) -> Verdict {
        let effective = effectiveTried(tried: tried, among: live.union(departed), kinds: kinds, evidence: evidence)
        if !live.subtracting(effective).isEmpty { return .handOn }
        if !departed.subtracting(effective).isEmpty { return .notRun }
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
