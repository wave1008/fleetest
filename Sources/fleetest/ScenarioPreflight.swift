// ScenarioPreflight.swift
// `fleetest run` / `fleetest api run` が dispatch.lock を取る**前**に、シナリオの名指しの打ち間違いを断る。
// デバイスにも書き込みにも触らない読むだけの検査 —— ロックを待ってから初めて断ると、
// `--wait-lock 3600` の回で1時間待って打ち間違いを知らされる。
// **既にビルド済みのときだけ**一覧を引く(ビルドが要る回はビルドをロックの内側に置く規律なので、
// ロックの前にビルドしない = その回の検査は従来どおりビルドの後)。一覧を引けない・
// 一覧に載らない形の指定は何も言わず通す(本検査は従来の場所が行う)。

import FTCore
import Foundation

enum ScenarioPreflight {
    /// `scenarios` が空・未ビルド・一覧が引けないときは何もしない。名指しが見つからないときだけ投げる
    /// (`ScenarioSelectionError` = 従来の場所と同じ文言)
    static func rejectUnknownScenarios(project: TestProject, scenarios: [String]) throws {
        guard !scenarios.isEmpty, !ScenarioHost.buildNeeded(project: project),
              let all = try? ScenarioHost.list(project: project), !all.isEmpty else { return }
        do {
            _ = try ScenarioSelection.resolveReportingCollapsed(
                scenarios, from: all, scenariosDir: project.scenariosDir)
        } catch let error as ScenarioSelectionError {
            throw error
        } catch {
            return
        }
    }
}
