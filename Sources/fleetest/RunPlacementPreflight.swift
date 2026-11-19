// RunPlacementPreflight.swift
// クラスの寄せ方(RR-8.3)の入口の検査と、RunOrchestrator を通らない逐次の経路の並べ替え・失敗の後の扱い。
// `fleetest run` と `fleetest api run` は同じ関数を呼ぶ(片方だけの検査にしない。RunPlacementParityTests が両方の呼び出しを固定)。

import ArgumentParser
import FTCore
import Foundation

enum RunPlacementPreflight {

    /// 選び方の確定後(フォルダ・--failed の後)に呼ぶ。dry-run では呼ばない(--debug では呼ぶ)。
    /// 違反は ValidationError。broadcast は断らず1行だけ出す(log)
    static func check(
        selected: [ScenarioInfo], all: [ScenarioInfo], measuresResponse: Bool, broadcast: Bool,
        log: (String) -> Void
    ) throws {
        if let message = ClassPlacementRules.selectionError(selected: selected, all: all) {
            throw ValidationError(message)
        }
        if measuresResponse, let message = ClassPlacementRules.measurementError(selected) {
            throw ValidationError(message)
        }
        if broadcast, let notice = ClassPlacementRules.sharedRunNotice(selected, mode: "--broadcast") { log(notice) }
    }
}

/// RunOrchestrator を通らない逐次の経路(--port 直指定の1本ずつの実行)用。並べ替えと、
/// @RunInOrder のクラスが失敗した後の同じクラスのテストを止める記帳(lane は "" の1本)
struct SequentialPlacementGate {
    private var gate = InOrderGate()

    init() {}

    /// 寄せるクラスのメンバーを連続させ、@RunInOrder は @Order の順にする(属性が無ければ元の並び)
    static func ordered(_ items: [ScenarioRunItem]) -> [ScenarioRunItem] {
        var byID: [String: [ScenarioRunItem]] = [:]
        for item in items { byID[item.info.id, default: []].append(item) }
        return ClassPlacementRules.ordered(items.map(\.info)).compactMap { info in
            guard var list = byID[info.id], !list.isEmpty else { return nil }
            let item = list.removeFirst()
            byID[info.id] = list
            return item
        }
    }

    static func ordered(_ infos: [ScenarioInfo]) -> [ScenarioInfo] { ClassPlacementRules.ordered(infos) }

    /// 実行せずに失敗として記録する理由(英語)。無ければ nil
    func skipReason(for info: ScenarioInfo) -> String? { gate.skipReason(for: info, lane: "") }

    mutating func record(_ info: ScenarioInfo, passed: Bool) { gate.record(info, lane: "", passed: passed) }
}
