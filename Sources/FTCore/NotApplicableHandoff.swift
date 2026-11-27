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

    /// 試した台と同じ種類(観測した機種 × runtime)の台は試した扱いにするか(iOS だけ。DR-214)。
    /// `kinds` = 鍵 → 観測した種類の集合。**不明(欄無し・空)は覆わない** —— 実行プロファイルの `model` は表示用で
    /// 識別に使わない(折りたたみ機を取りこぼして誤った緑にするのを防ぐ)。1つでも試した種類に無ければ覆わない。
    /// **試した側で数えるのは種類が1つだけの鍵** —— 機械をまたぐ親の鍵(エントリ)は台の集まりで、子は台を絞って一部しか使わないことがある
    /// (`ResolvedProfile.limitingDevices`)。種類の混ざったエントリの「対象外」は、使わなかった種類を試した証拠にならない
    public static func covered(_ key: String, tried: Set<String>, kinds: [String: Set<String>]) -> Bool {
        guard !tried.contains(key), let own = kinds[key], !own.isEmpty else { return false }
        let triedKinds = tried.reduce(into: Set<String>()) { result, key in
            if let kind = kinds[key], kind.count == 1 { result.formUnion(kind) }
        }
        return own.isSubset(of: triedKinds)
    }

    /// 試した台 + 試した台と同じ種類の台(`keys` の中から)
    public static func effectiveTried(tried: Set<String>, among keys: Set<String>, kinds: [String: Set<String>]) -> Set<String> {
        tried.union(keys.filter { covered($0, tried: tried, kinds: kinds) })
    }

    /// - tried: このシナリオを試して対象外と宣言した台(今回の台を含む)
    /// - live: いま run に居る同じ OS の台(試した台を含んでよい)
    /// - departed: run から落ちた(供給で合流できなかった・離脱した・終わった)同じ OS の台
    /// - kinds: 鍵 → 観測した種類(`covered`)。渡せる情報が無い呼び手は [:]
    /// 判定の順序に意味がある: 生きた未試行の台 > 落ちた未試行の台 > どちらも無い。
    public static func decide(tried: Set<String>, live: Set<String>, departed: Set<String>,
                              kinds: [String: Set<String>]) -> Verdict {
        let effective = effectiveTried(tried: tried, among: live.union(departed), kinds: kinds)
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
