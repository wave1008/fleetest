// StepExecutor+ActionHints.swift
// executeAction(+Actions)が失敗文・注記に添える案内と、その判定の小さな補助(行数の上限で +Actions から分けた)

import Foundation

extension StepExecutor {

    /// 既定の短い待ち(`waitSeconds:` 省略)のまま見つからなかったときだけ、延ばし方を添える。指定した待ちで見つからなかったなら待ちの長さが原因とは言えないので何も足さない
    static func defaultWaitHint(_ step: FlowStep) -> String {
        guard step.timeout == nil else { return "" }
        let seconds = String(format: "%.1f", defaultLocatorRetrySeconds)
        return ". Without waitSeconds: this command looks for the element for only about \(seconds) s;"
            + " if it appears later (for example right after a screen transition), add waitSeconds: to this step"
            + " (for example waitSeconds: 5); if it is not on this screen at all, neither waiting nor scrolling helps —"
            + " the element list below shows what is"
    }

    /// **Android で前面を離れたかもしれない後(`home()`・`back()`・別アプリ向けの `openURL` 等)に見つからなかった失敗文**。
    /// Android の肯定の操作は撃つ前の門を通らない(人もランチャーを押せる)ので撃って見つからず、`waitSeconds:` / `scroll:` という
    /// 従えない対処を勧めていた。前面を聞いて、対象アプリが前面に無いと答えたときだけ、その事実と戻し方を言う。
    /// 前面と答えた・答えなかった・プロセスが居ない(落ちた = 別の経路が扱う)ときは nil(従来の文)
    static func leftForegroundHint(isAndroid: Bool, mayHaveLeft: Bool, foreground: Probe<Bool>, processGone: Bool) -> String? {
        guard isAndroid, mayHaveLeft, !processGone, case .value(false) = foreground else { return nil }
        return ". The app under test is not in the foreground (a person could not tap it either), so waiting or scrolling will not"
            + " find it. Bring the app back first (tapAppIcon() or launchApp())"
    }

    /// select の撮り直しで、撮り直した要素が最初に掴んだ要素と同じ状態か(押せるか・ラベル・値・チェック)。違えば画面が先へ進んだ
    static func sameStateForRetake(_ first: ElementInfo, _ again: ElementInfo) -> Bool {
        first.enabled == again.enabled && first.label == again.label && first.value == again.value && first.checked == again.checked
    }

    /// `AndroidForegroundWindows.ownDialogs` が窓の名前に付ける語尾(片方だけ変えない)
    public static let ownDialogWindowMarker = "(the app's own dialog window)"

    /// **対象アプリ自身のダイアログが手前にあるとき、見つからない失敗で待ちを勧めず、そのダイアログを名指す**(ダイアログの窓は
    /// 木に載らず、裏の要素が解決できない = 待っても出ない。8/8: `waitSeconds:` を勧めていた)。申告が無い・引けないときは nil(従来の文)。
    /// 「裏にある」とは言い切らない(木は窓を跨いで読まれるので、対象がダイアログの中にある場合もある)
    static func ownDialogHint(windows: [String]) -> String? {
        let own = windows.filter { $0.hasSuffix(ownDialogWindowMarker) }
        guard !own.isEmpty else { return nil }
        return " — the app's own dialog window is in front of the screen (\(own.joined(separator: ", "))); if the target is behind it,"
            + " close the dialog first — waiting will not bring back what is behind it"
    }

    func ownDialogHint() -> String? {
        guard isAndroid, let lines = foregroundWindowLines else { return nil }
        return Self.ownDialogHint(windows: lines(lastLaunchedAppBundleID))
    }

    func leftForegroundHint() async -> String? {
        guard isAndroid, appMayHaveLeft, let prober = foregroundProber, let bundleID = lastLaunchedAppBundleID else { return nil }
        let candidates = [bundleID] + [appUnderTestBundleID].compactMap { $0 }.filter { $0 != bundleID }
        let foreground = await Self.anyInForeground(prober, bundleIDs: candidates)
        var gone = false
        if let alive = appAliveProbe, case .value(false) = foreground { gone = await alive(bundleID) == false }
        return Self.leftForegroundHint(isAndroid: isAndroid, mayHaveLeft: appMayHaveLeft, foreground: foreground, processGone: gone)
    }

    /// 見つからないときの `scroll:` の案内。向きを書いていない触る操作で、画面に送れる一覧があるときだけ足す(tap / hold は scroll: を、
    /// scroll: を持たない操作(doubleTap 等)は先に送る手を案内する)
    /// (スクロールで木から消えた部品 = 隠れるバーに `waitSeconds:` だけを案内すると、従っても直らない。10周目の探索 iultra F5)。
    /// `defaultWaitHint` とは別に持つ(MCP があちらの文言をそのまま取り除くので混ぜない)
    /// 探索がアプリの消失・前面を離れたことで止まった = 対象の有無を確かめていない(「見つからない」の記録・select の空要素にしない)
    static func searchStoppedWithoutLooking(_ result: ScrollSearchResult) -> Bool {
        result.appGone != nil || result.appLeftForeground != nil
    }
}
