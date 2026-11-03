// シナリオごとに「最後に通ってから落ちたデバイス」を覚え、レーンの連続失敗(WorkerCircuitBreaker)に
// 数えるかを決める(純粋ロジック + `.fleetest/scenario-failures-<scope>.json` の読み書き)。
//
// 数えないのは「同じシナリオが、最後に通ってから**別のデバイス**でも落ちている」失敗だけ。どのデバイスでも落ちる
// シナリオ(期待の誤り・書きかけ)の赤は、そのデバイスの不調の証拠にならない(推測ではなく、別のデバイスで落ちた
// という事実で決める。失敗の分類は置かない)。同じデバイスだけで落ち続けるシナリオ・まだ記録の無いシナリオは数える
// (ロック画面のままの端末は、他の端末では通るシナリオで落ちる = 守る形は変わらない)。
// 1 run で各シナリオを1回ずつ回すだけの初回は区別の材料が無いので、従来どおり数える。
//
// - 通ったら、そのシナリオの同じ OS の記録を消す(以後の失敗は再び1台目から)。対象外(notApplicable)では消さない(走らなかっただけ)。
// - 期限は置かない(LaneFailureStreakStore と同じ。通れば消える)。
// - 壊れた・読めないファイルは空として扱う。書き込みは全置換で、run の中の書き手は RunOrchestrator の錠の中の1か所。
//   同じプロジェクトの run を同時に回すと後に書いた方が残る(失うのは数えない根拠だけ = 従来どおり数える側に倒れる)。

import Foundation

public struct ScenarioFailureWitnesses: Codable, Equatable, Sendable {
    /// シナリオ ID → 最後に通ってから落ちたデバイス(`RunOrchestrator.workerID`)
    public private(set) var failedOn: [String: Set<String>] = [:]

    public init(failedOn: [String: Set<String>] = [:]) {
        self.failedOn = failedOn
    }

    /// 失敗を記録し、レーンの連続失敗に数えるかを返す。「別のデバイス」は**同じ OS のデバイスだけ**(鍵の `<platform>:` が同じ)。
    /// OS の片方だけの不具合で落ちたシナリオが、もう片方の不調機の失敗を見逃させない
    public mutating func recordFailure(scenario: String, worker: String) -> Bool {
        let before = failedOn[scenario, default: []]
        failedOn[scenario, default: []].insert(worker)
        let platform = Self.platform(of: worker)
        return !before.contains { $0 != worker && Self.platform(of: $0) == platform }
    }

    private static func platform(of worker: String) -> Substring {
        worker.split(separator: ":", maxSplits: 1).first ?? Substring(worker)
    }

    /// 通ったデバイスと同じ OS の記録だけ消す(片方の OS でだけ壊れたシナリオの記録を、もう片方の OS の緑で消さない)
    public mutating func recordPass(scenario: String, worker: String) {
        let platform = Self.platform(of: worker)
        failedOn[scenario] = failedOn[scenario]?.filter { Self.platform(of: $0) != platform }
        if failedOn[scenario]?.isEmpty == true { failedOn[scenario] = nil }
    }

    public static func fileURL(stateDir: URL, scope: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        let encoded = scope.addingPercentEncoding(withAllowedCharacters: allowed) ?? scope
        return stateDir.appendingPathComponent("scenario-failures-\(encoded).json")
    }

    public static func load(stateDir: URL, scope: String) -> ScenarioFailureWitnesses {
        guard let data = try? Data(contentsOf: fileURL(stateDir: stateDir, scope: scope)),
              let value = try? JSONDecoder().decode(ScenarioFailureWitnesses.self, from: data) else { return .init() }
        return value
    }

    /// 空なら削除(「空と書かれたファイル」と「無い」の2形を持たない)
    public func save(stateDir: URL, scope: String) {
        let url = Self.fileURL(stateDir: stateDir, scope: scope)
        guard !failedOn.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
