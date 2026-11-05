// 「起こしたアプリのプロセスが居ないのに、木の持ち主が別のアプリになっている」の判定を1箇所に置く
// (DSL の StepExecutor と MCP の ft_batch / ft_scroll_to が StepExecutor 経由で共有する。判定の材料は `ForegroundState.judge`)。
// Android のアプリが落ちると前面はランチャーや下のアプリへ移る。同じ id を持つ別アプリが前面なら、セレクタは別アプリの木で
// 解決して ok になる(誤った成功)ので、プロセスが居ないと確定したときだけ撃たずに断る。
// **前面が別アプリというだけでは断らない**(openURL・権限ダイアログ・アプリ内のリンクで別アプリへ移るシナリオは正しい)。

import Foundation

public enum AppProcessGone {

    /// `launched` のプロセスが居ないと確定し、木の持ち主(`owner`)が別のものか。
    /// `processRunning` は**持ち主が違うときだけ**呼ぶ(通常の呼び出しでは adb を払わない)。nil = 判定できない(断らない)
    public static func isGone(launched: String, owner: String?,
                              processRunning: () async -> Bool?) async -> Bool {
        guard let owner, !owner.isEmpty, owner != launched else { return false }
        // 照会を撃つ前に、プロセスの有無が結論を変えない持ち主(SpringBoard・システムのダイアログ)を除く
        guard owner != ForegroundState.springboard, !ForegroundState.systemDialogPackages.contains(owner) else { return false }
        let running = await processRunning()
        let verdict = ForegroundState.judge(ForegroundFacts(
            launched: launched, sessionBundleID: owner,
            processRunning: running.map { .value($0) } ?? .notAnswerable))
        return verdict == .processGone
    }

    /// 断り文(事実だけ。操作は撃つ前に断る = 何も送っていない。検証は元々何も送らない)
    public static func message(launched: String, owner: String) -> String {
        "the app process (\(launched)) is not running, and the screen read for this step belongs to \(owner)"
            + " — nothing was sent. The selector can match another app's screen, so the result would not be about \(launched)."
            + " Relaunch \(launched) before the next step"
    }

    /// 探索の途中で落ちた回の断り文(それまでに送りを撃っている = `message` の「何も送っていない」は言わない)。
    /// 送りがどこに当たったかは測っていないので言わない
    public static func messageAfterSearch(launched: String, owner: String, sentSwipes: Int) -> String {
        "the app process (\(launched)) is not running, and the screen read during the search now belongs to \(owner)"
            + " — the search stopped after \(sentSwipes) swipe(s). The selector can match another app's screen, so the result"
            + " would not be about \(launched). Relaunch \(launched) before the next step"
    }
}
