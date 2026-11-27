// 台の条件(@RequiresDevice / @ExcludesDevice。DR-237)に合う台が無いまま残った item の結論と、宣言と実行時の食い違いの注記。
// 判定は `DeviceRequirementGate`(キューの取り出しと同じ関数)。ここは結果の記録だけ。

import Foundation

extension RunOrchestrator {
    /// ドレインで残った item が台の条件を持ち、参加した台のどれにも合わないとき、失敗 / 対象外に確定する。
    /// 戻り値 = 失敗に数える本数(対象外は 0)・nil = 結論ではない(条件が無い・合う台がある・台が1つも参加していない = 通常のドレイン)。
    /// 読めなかった台が1台でもあれば失敗(`.noWorker`・事実だけ)、全台が読めて合わなければ `.notApplicable`(緑)。
    /// `perDevice` = broadcast(1レーン1キュー。記録の worker はそのデバイス)
    func concludeDeviceRequirementGap(_ item: ScenarioRunItem, queue: ScenarioQueue, platform: String, worker: String?,
                                      perDevice: Bool) async -> Int? {
        guard let requirements = item.info.deviceRequirements, !requirements.isEmpty,
              let conclusion = DeviceRequirementGate.conclusion(requirements, lanes: await queue.joinedLaneTraits(),
                                                                perDevice: perDevice) else { return nil }
        switch conclusion {
        case .failed(let reason):
            continuation.yield(.flowSkipped(flowURL: item.url, reason: reason))
            recorder?.recordSkipped(unit: item.unitKey, title: item.info.title, platform: platform, worker: worker,
                                    reason: reason, kind: .noWorker)
            return 1
        case .skipped(let reason):
            // 走らせていないので担当のワーカーは無い(ログ・NDJSON の組を保つ疑似ワーカー "run")
            continuation.yield(.flowStarted(worker: "run", flowURL: item.url, flowName: item.info.id, isDirty: false))
            continuation.yield(.flowFinished(worker: "run", flowURL: item.url, passed: true, reportURL: nil, fm: nil,
                                             notApplicableReason: reason))
            recorder?.recordSkipped(unit: item.unitKey, title: item.info.title, platform: platform, worker: worker,
                                    reason: reason, kind: .notApplicable)
            deviceGapSkipped.withLock { $0 += 1 }
            return 0
        }
    }

    /// サマリの1行(コンソールのログ。結果 JSON・NDJSON の欄は足さない)
    func announceNoMatchingDevice() {
        let count = deviceGapSkipped.value
        guard count > 0 else { return }
        continuation.yield(.workerLog(worker: "run", message: "\(count) scenario(s) had no matching device"))
    }

    /// 宣言した条件に合う台で、実行時に対象外と宣言された(宣言の誤り・書き漏らしの手掛かり)。DR-214 の回し直しは従来どおり続ける
    func declaredMatchNote(item: ScenarioRunItem, worker: RunWorker, declared: String) -> String? {
        guard DeviceRequirementGate.permits(item.info.deviceRequirements, traits: worker.effectiveTraits),
              let requirements = item.info.deviceRequirements, !requirements.isEmpty else { return nil }
        return "\(item.info.id): declared device conditions matched on \(worker.label) but the run found it not applicable"
            + " (\(declared)); conditions: \(DeviceRequirementGate.describe(requirements))"
    }
}
