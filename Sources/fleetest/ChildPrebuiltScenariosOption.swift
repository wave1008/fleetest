// 親が送ったビルド済みシナリオ実行バイナリを子(ランナー上の `run` / `api run`)が受ける内部フラグ。
// `ChildDeviceTraitsOption` と同じ形: RunCommonOptions には置かず両コマンドが OptionGroup で持つ(ヘルプに出ない =
// RunCommandFlagParityTests の表の対象外)。送る側は `RemoteRunDispatcher.performDispatch` の1箇所。

import ArgumentParser
import FTBridgeClient
import FTCore
import Foundation

struct ChildPrebuiltScenariosOption: ParsableArguments {
    @Option(name: .customLong("prebuilt-scenarios"),
            help: ArgumentHelp(
                "Internal: path of the scenario executable the parent built and sent. Set by the parent; not for hand use",
                visibility: .hidden))
    var path: String?

    @Option(name: .customLong("prebuilt-origin-root"),
            help: ArgumentHelp(
                "Internal: the package root of the machine that built the prebuilt scenarios (stripped from report paths)",
                visibility: .hidden))
    var originRoot: String?

    /// 渡されていれば受け入れる(使えなければ登録せずログ1行 = 子は今までどおりビルドする)。
    /// **ビルドより前に呼ぶ**(`ScenarioHost.build` / `buildNeeded` / `runnerURL` が登録を見る)
    func install(project: TestProject, log: @escaping (String) -> Void) {
        guard let path else { return }
        ScenarioHost.usePrebuilt(project: project, binary: URL(fileURLWithPath: path), originRoot: originRoot,
                                 toolRoot: (try? RepoRoot.find())?.path, log: log)
    }
}
