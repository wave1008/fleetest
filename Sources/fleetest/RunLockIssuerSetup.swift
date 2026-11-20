// RunLockIssuerSetup.swift
// マシンをまたぐ run の発行元(DeviceMachineRunner / ApiRunMachineFanout / MultiTargetRunner)が、run 全体のロック(RR-8.5)の
// サーバーを起こす入口。ロックの範囲は run × プロジェクト。サーバーは FTCore.RunLockIssuer(backend = 発行元の RunMemoHub)。
// 起こした発行元は、**自分と同じマシンで起こす子(`--runner local`)にだけ** `--lock-socket <path>` を渡す(`childArgs` / `buildArgs`)。
// リモートの子へは渡さない: 渡さなければ子は「ssh 越しは使えない」で呼んだ時点で失敗する(黙って割れない)。

import FTCore
import Foundation

enum RunLockIssuerSetup {
    /// 待ちの絶対の上限(秒): この発行元が配るシナリオの**最も長い実効の scenarioTimeout**(`@Test(scenarioTimeout:)` を含む)。
    /// 実効値は子と同じ解決(`@Test` > `--scenario-timeout` / プロファイル > 既定)。プロファイルが複数ならその最大
    static func waitCapSeconds(project: TestProject, profiles: [String], setOverrides: [String: RunProfileSetValue],
                               explicitScenarioTimeout: Int? = nil, scenarioTimeouts: [Int?]) -> Int {
        let settings: [Int?] = profiles.map { name in
            if let explicitScenarioTimeout { return explicitScenarioTimeout }
            return (try? ProfileResolver.resolve(project: project, runName: name, workspaceOverride: nil,
                                                 overrides: setOverrides))?.scenarioTimeout
        }
        return (settings.isEmpty ? [nil] : settings)
            .map { RunLockUsage.waitCapSeconds(scenarioTimeouts: scenarioTimeouts, settingsTimeout: $0) }.max()
            ?? ScenarioHost.defaultScenarioTimeout
    }

    /// ソースがロックを使うときだけ起こす(使わなければ nil)
    static func start(project: TestProject, profiles: [String], setOverrides: [String: RunProfileSetValue],
                      explicitScenarioTimeout: Int? = nil, scenarioTimeouts: [Int?], hub: RunMemoHub,
                      log: @escaping @Sendable (String) -> Void) -> RunLockIssuer? {
        guard RunLockUsage.projectUsesLocks(project) else { return nil }
        let cap = waitCapSeconds(project: project, profiles: profiles, setOverrides: setOverrides,
                                 explicitScenarioTimeout: explicitScenarioTimeout, scenarioTimeouts: scenarioTimeouts)
        return RunLockIssuer.startIfUsed(project: project, waitCapSeconds: cap, hub: hub, log: log)
    }
}
