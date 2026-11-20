// RunLockIssuerSetup.swift
// マシンをまたぐ run の発行元(DeviceMachineRunner / ApiRunMachineFanout / MultiTargetRunner)が、run 全体のロック(RR-8.5)の
// サーバーを起こす入口。ロックの範囲は run × プロジェクト。サーバーは FTCore.RunLockIssuer(backend = 発行元の RunMemoHub)。
// 起こした発行元は、手元の子(`--runner local`)には手元の待ち受けを、リモートの子(中継役)にはディスパッチごとに開いた待ち受けと
// 手元の制御用の待ち受けを `--lock-socket` / `--lock-control-socket` で渡す(`childArgs` / `buildArgs`。中継役が ssh の転送を張る)。

import FTCore
import Foundation

enum RunLockIssuerSetup {
    /// 待ちの絶対の上限(秒): この発行元が配るシナリオの**最も長い実効の scenarioTimeout**(`@Test(scenarioTimeout:)` を含む)。
    /// 実効値は子と同じ解決(`@Test` > プロファイル(`--set scenarioTimeout=` を当てたもの) > 既定)。**子はプロファイル経路では
    /// `--scenario-timeout` を使わない**(help: "with --profile the profile scenarioTimeout wins" = `ScenarioExecutionSettings(resolved)`)ので、
    /// ここでも見ない。プロファイルが複数ならその最大
    static func waitCapSeconds(project: TestProject, profiles: [String], setOverrides: [String: RunProfileSetValue],
                               scenarioTimeouts: [Int?]) -> Int {
        let settings: [Int?] = profiles.map { name in
            (try? ProfileResolver.resolve(project: project, runName: name, workspaceOverride: nil,
                                                 overrides: setOverrides))?.scenarioTimeout
        }
        return (settings.isEmpty ? [nil] : settings)
            .map { RunLockUsage.waitCapSeconds(scenarioTimeouts: scenarioTimeouts, settingsTimeout: $0) }.max()
            ?? ScenarioHost.defaultScenarioTimeout
    }

    /// ソースがロックを使うときだけ起こす(使わなければ nil)
    static func start(project: TestProject, profiles: [String], setOverrides: [String: RunProfileSetValue],
                      scenarioTimeouts: [Int?], hub: RunMemoHub,
                      log: @escaping @Sendable (String) -> Void) -> RunLockIssuer? {
        guard RunLockUsage.projectUsesLocks(project) else { return nil }
        let cap = waitCapSeconds(project: project, profiles: profiles, setOverrides: setOverrides,
                                 scenarioTimeouts: scenarioTimeouts)
        return RunLockIssuer.startIfUsed(project: project, waitCapSeconds: cap, hub: hub, log: log)
    }
}

extension RunLockIssuer {
    /// 子(1回のディスパッチ)へ渡す `--lock-socket` / `--lock-control-socket` の値。**呼ぶたびにリモートの待ち受けを新しく開く**
    /// (ディスパッチごとに別の待ち受け = 同じ機械の別のディスパッチの持ち主不明と混ざらない)ので、子の起動ごとに1回だけ呼び、
    /// 子が終わったら `closeRemoteListener` で閉じる。
    /// - 手元の子(`local`): その子が直接つなぐ手元の待ち受け(制御用は要らない・閉じるものは無い)
    /// - リモートの機械: **このディスパッチの待ち受け**(中継役が ssh の `-R` の転送先と識別子にする)と、中継役が手元からつなぐ手元の待ち受け
    /// 開けなければ nil(手元の待ち受けで代用しない = リモートの run が手元の出どころとして扱われてしまう)
    func openChildSockets(machineLabel: String) -> (lockSocket: String, control: String?)? {
        if machineLabel == DeviceMachineGrouping.localDisplayName {
            childLaunched()
            return (socketPath, nil)
        }
        guard let dispatchSocket = openRemoteListener(machine: machineLabel) else { return nil }
        childLaunched()
        return (dispatchSocket, socketPath)
    }

    /// 子が終わった後にその待ち受けを閉じる(手元の待ち受けは閉じない)
    func closeChildSockets(_ sockets: (lockSocket: String, control: String?)?) {
        guard let sockets else { return }
        if sockets.control != nil { closeRemoteListener(path: sockets.lockSocket) }
        childExited()
    }
}
