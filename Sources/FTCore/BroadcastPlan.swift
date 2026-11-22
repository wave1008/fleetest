// BroadcastPlan.swift
// `fleetest run --broadcast`(ブロードキャスト実行)の分配計画。RunOrchestrator が
// 「platform 別の共有キュー」の代わりに「レーン(デバイス)別のキュー」を作るための純粋関数。
// 供給・インストール・フック・スタッガ・復帰・レポートは通常 run と同じ経路を通す(変えるのは
// キューの切り方だけ。RunOrchestrator.run の dispatch 分岐参照)。

import Foundation

/// RunOrchestrator.run のシナリオ分配の仕方
public enum ScenarioDispatch: Sendable {
    /// platform 別の共有キューから各ワーカーが早い者勝ちで取る(各シナリオは1台で1回)
    case shared
    /// 各レーンが同じセットを1回ずつ回す(`fleetest run --broadcast`)。lanes = 回るべき
    /// デバイス。**レーンとワーカーの突き合わせは `BroadcastPlan.laneKey(of:)`**(論理名)
    case broadcast(lanes: [BroadcastLane])
    /// 空いたワーカーが外の配り手(マシンをまたぐ run の親。`--work-queue`)から1本ずつもらう。
    /// キューは空で始まり、カタログ(全候補)にある ID だけ配られる。配り手が platform ごとに nil を
    /// 返したらその platform は終わり。件数は配られた分だけ(total は配るたびに増える)
    case pulled(source: any ScenarioPullSource)
}

/// 配り手の返事(`ScenarioPullSource.next`)。
public enum PullAnswer: Equatable, Sendable {
    case unit(ScenarioUnitKey)
    /// その platform にはもう無い(以後そのレーンは聞き直さない)
    case exhausted
    /// 配る物は今は無いが尽きてもいない。手元のキューを見直してから聞き直す(DR-214 ②: このマシンが対象外の回し直しを始めたとき、
    /// 親が保留していたこのマシンの要求へ返す。返さないと、保留中のレーンが手元に戻った item を取れず、2台のマシンが互いの回し直しを
    /// 待ち合って終わらない)
    case recheck

    public var unit: ScenarioUnitKey? {
        if case .unit(let unit) = self { return unit }
        return nil
    }
}

/// `ScenarioDispatch.pulled` の配り手。
/// **呼び出しは並行に来る**(同じ platform の複数ワーカー)・待たせる = 返事を遅らせる
public protocol ScenarioPullSource: Sendable {
    /// lane = `RunWorker.logicalName`(空いたデバイスの名前。無ければ空文字)
    func next(platform: String, lane: String) async -> PullAnswer
    /// 中断: 返事を待っている要求と以後の要求を全部 nil で終わらせる。**親の返事を当てにしない** ——
    /// 渡し済みの返事が届かなかったレーンは、親が中断で none を返す相手にならず、子が終わらなくなる
    func stopWaiting()
    /// 対象外(DR-214): 機械の中に回し直す先が無かった対象外の item を、機械の外(他のマシンの未試行の台)へ回せるか親に聞く。
    /// `departedUntried` = このキューの中で試していない台が落ちている。中断・親の消失は `.skipped`(従来の確定)。
    /// **既定実装を置かない**(新しい配り手が問い合わせを忘れると、対象外が確定のまま 0 本実行の緑になる)
    func declareNotApplicable(platform: String, lane: String, unit: ScenarioUnitKey,
                              departedUntried: Bool) async -> NotApplicableHandoff.Verdict
    /// 対象外(DR-214): 配られた単位を機械の中の別の台へ回し直し始めた(`on: true`)・終わった(`on: false`)ことを親へ知らせる(返事なし)。
    /// **既定実装を置かない**(知らせ忘れると、親が他のマシンの尽きたレーンを終わらせ、後の対象外が「未試行の台が落ちた」赤になる)
    func noteKept(unit: ScenarioUnitKey, on: Bool)
}

/// ブロードキャストの1レーン = 実行プロファイルの1デバイス
public struct BroadcastLane: Hashable, Sendable {
    /// `RunWorker.logicalName`(プロファイルのデバイス名)と一致させる
    public let key: String
    public let platform: String

    public init(key: String, platform: String) {
        self.key = key
        self.platform = platform
    }
}

public struct BroadcastPlan: Sendable {
    /// レーン key → そのレーンが回す item(`lane` を刻印済み。順序は入力のまま = LPT の
    /// 並びがレーン内でそのまま効く)。**0本のレーンは載せない**(キューを作ってもワーカーを
    /// 温めるだけで何もしない)
    public let queues: [String: [ScenarioRunItem]]
    /// 宣言 platform がどのレーンにも無い item(shared の「担当ワーカーなし」と同じ扱い)
    public let unassigned: [ScenarioRunItem]
    /// (シナリオ × レーン)の総数 = この run が回す本数
    public var total: Int { queues.values.reduce(0) { $0 + $1.count } }

    /// - items: 実行する順に並んだシナリオ。**platform 未指定(nil)は全レーンへ配る**
    ///   (shared は既定 platform の1台でしか走らせないが、ブロードキャストの目的は
    ///   「全デバイスがそれぞれ準備される」ことなので、OS を問わないシナリオは全台に要る)。
    ///   明示 platform はその platform のレーンだけ
    /// - lanes: 同じ key が2つ以上あれば先勝ち(レーン = デバイス論理名で一意のはず。
    ///   重ねると同じキューを2ワーカーが取り合い、片方のデバイスに走らない本が出る)
    public static func make(items: [ScenarioRunItem], lanes: [BroadcastLane]) -> BroadcastPlan {
        var seen = Set<String>()
        let uniqueLanes = lanes.filter { seen.insert($0.key).inserted }
        let lanePlatforms = Set(uniqueLanes.map(\.platform))
        var queues: [String: [ScenarioRunItem]] = [:]
        var unassigned: [ScenarioRunItem] = []
        for item in items {
            if let platform = item.info.platform, !lanePlatforms.contains(platform) {
                unassigned.append(item)
                continue
            }
            for lane in uniqueLanes where item.info.platform == nil || item.info.platform == lane.platform {
                queues[lane.key, default: []].append(item.with(lane: lane.key))
            }
        }
        return BroadcastPlan(queues: queues, unassigned: unassigned)
    }

    /// ワーカーがどのレーンのぶんを回すか。プロファイル経路は `logicalName`(復帰で label =
    /// ポートが変わっても同じデバイスは同じ key に戻る)。非プロファイル経路(--port)は label
    public static func laneKey(of worker: RunWorker) -> String {
        worker.logicalName ?? worker.label
    }
}
