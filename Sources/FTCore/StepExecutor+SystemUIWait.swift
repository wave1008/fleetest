// StepExecutor+SystemUIWait.swift
// 操作の前の待ち(システム UI の被さり・アラートの除去・有効になるまで・打鍵先の焦点の取り直し)

import Foundation

extension StepExecutor {
    /// **OS のシステム UI が被さっている間は操作させない**(`FTCore.SystemUIGate`)。
    /// 戻り値 nil = 進んでよい / 非 nil = そのままステップの結果にする(失敗)。
    ///
    /// in-app の注入は OS のイベント経路を通らないので、覆われていても届いてしまう
    /// (= 人手では不可能な操作)。判定は XCUITest ランナーの `GET /systemalert` だけを見る
    /// (**約 73ms**。木を全部撮る 185ms は毎ステップ払えない。`applicationState` は
    /// 端末で割れて使えなかった —— SystemUIGate の doc)。
    ///
    /// 順序は3つ。**今の挙動を包含する**ように並べてある:
    ///   ① 対象が fallback(SpringBoard)の木で解決できる → 何もしない
    ///      = シナリオ自身がそのアラートを操作している。下のドライバ切替がそのまま拾う
    ///   ② 登録済みの `iosAlertHandler` で閉じられる → 閉じて木を取り直す
    ///   ③ どちらでもない → **撃たずに待つ**。消えたら進み、待ち切れなければ失敗
    ///
    /// 予算はステップの `timeout`、無ければ既定の待ち(**新しい数字は作らない**。
    /// `waitUntilEnabled` と同じ規律)。
    ///
    /// **`iosAlertHandler` の登録が残っているときだけ働く**。
    /// アラートが出る操作は書き手が知っているので直前に登録でき、**登録の無い実行に
    /// 1往復(約 73ms)も払わせない**。登録があるのに一致するボタンが無いときは③で止める ——
    /// 登録は「次にアラートが出る」という予告でもあるため。
    /// fallback(XCUITest ランナー)が無い構成も同様に何もしない。
    ///
    /// **発火した登録は台帳から外れる**(1回の登録 = 1枚のアラート)。全部外れたら
    /// 以後この関数は即 nil を返す = 監視の解除。
    /// **アラートは重なり得る**ので、閉じたあとは戻らずに**もう一度確かめてから**進む
    func waitOutSystemUI(step: FlowStep,
                         phase: inout PhaseAccumulator) async throws -> StepResult.Status? {
        guard systemAlertWatchlist.isWatching, let fb = fallbackDriver else { return nil }
        let clock = ContinuousClock()
        var start = clock.now
        var probe = await probeSystemAlert(fb, phase: &phase)
        guard SystemUIGate.isCovered(probe) else { return nil }

        let deadline = clock.now.advanced(by: .seconds(step.timeout ?? tunables.defaultTimeout))
        var backoff = PollBackoff()
        var covering = SystemUIGate.describeCovering(probe)
        // **最後に読めたボタンの並び**を持ち回る(失敗の言い分に実際の名前を出すため。
        // 読めた回のものを残す = 消えかけの1枚で空になっても直前の観測を捨てない)
        var actualButtons = probe?.buttons ?? []
        while true {
            // **予算は毎周確かめる**(②で閉じ続けられる限り回るので、③だけに置くと
            // 「閉じても消えない」画面で無限に回る ——
            // 変異テストで実際にハングして見つけた。消費が有限なのは偶然の歯止めであって設計ではない)
            guard clock.now < deadline else {
                return failed(.systemUICovered,
                              SystemUIGate.failureMessage(covering: covering,
                                                          actualButtons: actualButtons,
                                                          declaredButtons: systemAlertWatchlist.describedRules))
            }
            start = clock.now
            let fsnap = try await fb.snapshot()
            phase.snapshotMs += Self.ms(clock.now - start)
            // ① シナリオ自身がアラートを操作している
            if LocatorResolver.resolveDetailed(step: step, in: fsnap) != nil { return nil }
            // ② 宣言があれば閉じる。**閉じたら戻らずに確かめ直す** —— 権限アラートは
            //    重なることがあり(位置情報の直後に通知など)、1枚閉じただけで進むと
            //    2枚目に覆われたまま撃つことになる
            if await dismissSystemAlert(in: fsnap, via: fb) != nil {
                noteCodesThisStep.insert(.waitedForSystemUI)
                probe = await probeSystemAlert(fb, phase: &phase)
                covering = SystemUIGate.describeCovering(probe) ?? covering
                if let read = probe?.buttons, !read.isEmpty { actualButtons = read }
                if !SystemUIGate.isCovered(probe) { return nil }
                continue   // 次の1枚を同じ順序で扱う
            }
            // ③ 撃たずに待つ(予算の確認はループ先頭)
            start = clock.now
            try await Task.sleep(for: backoff.nextDelay())
            phase.waitMs += Self.ms(clock.now - start)
            probe = await probeSystemAlert(fb, phase: &phase)
            covering = SystemUIGate.describeCovering(probe) ?? covering
            if let read = probe?.buttons, !read.isEmpty { actualButtons = read }
            if !SystemUIGate.isCovered(probe) {
                noteCodesThisStep.insert(.waitedForSystemUI)
                return nil
            }
        }
    }

    /// **fallback の木にシステム許可アラートが居たら、登録(iosAlertHandler)のボタンを押す**。
    /// 戻り値 = 押したラベル(nil = 押していない)。呼び出し側は木を取り直して解決をやり直す。
    ///
    /// 呼ぶのは「**要求された要素が primary でも fallback でも解決できなかった**」ときだけ ——
    /// 解決できているなら、シナリオ自身がそのアラートを操作しようとしている(`tap("許可")` /
    /// `ifCanSelect("許可")`)ので、自動処理が横から奪ってはいけない。
    /// 判断は FTCore.SystemAlertDismissal の1箇所(推測しない理由もそこ)。
    ///
    /// どれを押すか・押した後の台帳からの除去は **台帳(`SystemAlertWatchlist`)が全部持つ**。
    /// ここは選定 → タップ → 確定記録の順序だけ: タップは失敗し得るので、押せたと確定してから
    /// 記録する。押し続けても終わらない画面は `waitOutSystemUI` の予算が打ち切る
    @discardableResult
    public func dismissSystemAlert(in snapshot: SnapshotResponse,
                                   via fallback: AppDriver) async -> String? {
        guard let (button, index) = systemAlertWatchlist.buttonToTap(in: snapshot.elements),
              let label = button.label else {
            return nil
        }
        do { try await fallback.tap(ref: button.ref) } catch { return nil }
        systemAlertWatchlist.notePressed(index)
        onSystemAlertDismissed?(
            SystemAlertDismissal.actionDescription(pressed: button, in: snapshot.elements))
        return label
    }

    /// 対象が**操作可能になるまで**待つ(`tap` だけ)。戻り値 nil = 待たなかった/待ち切れなかった
    /// (呼び手はそのまま撃つ)。予算はステップの `timeout`、無ければ既定の待ち
    /// (`tunables.defaultTimeout`。**新しい数字は作らない**)。
    ///
    /// **`enabled` を明示したセレクタでは待たない** —— `&&enabled=false` は
    /// 「無効なものを狙って掴む」宣言なので、待つと必ず予算を捨てる
    func waitUntilEnabled(step: FlowStep, phase: inout PhaseAccumulator) async throws
        -> (element: ElementInfo, snapshot: SnapshotResponse, waitedMs: Int)? {
        let constrained = ([step.locator] + (step.fallbacks ?? []))
            .contains { $0?.enabled != nil }
        guard !constrained else { return nil }
        let clock = ContinuousClock()
        let began = clock.now
        let deadline = began.advanced(by: .seconds(step.timeout ?? tunables.defaultTimeout))
        var backoff = PollBackoff()
        while clock.now < deadline {
            var start = clock.now
            try await Task.sleep(for: backoff.nextDelay())
            phase.waitMs += Self.ms(clock.now - start)
            start = clock.now
            var snapshot = try await freshSnapshot(.afterOwnMove)
            phase.snapshotMs += Self.ms(clock.now - start)
            // **待っている間に湧いた割り込みはここで閉じる**。待ちは
            // 「撃つまでの時間」を伸ばすので、閉じないと**モーダルが被さる窓を自分で広げる**
            // ことになる(有効になった瞬間に覆いの上を撃つ)。解決の前に閉じるのは
            // executeAction 入口と同じ規律。宣言が無ければコストゼロ
            try await dismissInterruption(in: &snapshot, phase: &phase)
            guard let (element, _) = LocatorResolver.resolve(step: step, in: snapshot) else { continue }
            if element.enabled {
                return (element, snapshot, Self.ms(clock.now - began))
            }
        }
        return nil
    }

    /// 直前のタップが**叩いた対象へ焦点を立てられていなかった**ときに、入れ直す先を決める。
    /// nil = フォーカス中要素へそのまま送ってよい(焦点が叩いた対象そのもの/内側にある、
    /// または先が一意に決まらない)。**焦点が叩いた対象の外の別の欄に残っているだけでも
    /// 救済へ進む**(前の欄の焦点が外れないまま容器を叩く Android の形)。
    /// **木は撮り直す** —— ref は木ごとに振り直されるので、タップ時の ref は使えない。
    /// 判定と選び方は `InputFocusRescue`(純関数)に置く
    func retypeTargetIfUnfocused(after tapped: ElementInfo,
                                 phase: inout PhaseAccumulator) async throws -> ElementInfo? {
        let clock = ContinuousClock()
        let start = clock.now
        var snapshot = try await freshSnapshot(.afterOwnMove)
        phase.snapshotMs += Self.ms(clock.now - start)
        // 焦点が無い理由が**割り込みに持っていかれた**ことなら、閉じてから見る
        // (閉じずに入れ先を選ぶと、覆いの下の欄を名指しして ref で撃つことになる)
        try await dismissInterruption(in: &snapshot, phase: &phase)
        guard InputFocusRescue.focusIsElsewhere(from: tapped, in: snapshot.elements) else { return nil }
        guard let field = InputFocusRescue.fieldToType(after: tapped, in: snapshot.elements, before: tapTreeForRescue) else { return nil }
        // 呼び出し元(type のキーボード押し上げ検知)へ「打つ前」の状態を渡す橋渡し
        // (retypeRescueKeyboardFrame の doc。戻り値の型は変えない)
        retypeRescueKeyboardFrame = snapshot.keyboardFrame
        retypeRescueTreeBefore = snapshot.elements
        return field
    }

}
