// ブリッジが**届けていないと確定できる**形で断ったときの撃ち直し。古い ref(DriverError.staleRef)は木を撮り直して引き直し、
// システムアラート(DriverError.systemAlertBlocked)は登録(iosAlertHandler)で閉じてから撃ち直す。
// 呼び口は StepExecutor.execute の executeAction 呼び出し1箇所。

import Foundation

extension StepExecutor {

    /// 引き直してよいかの判定。**staleRef だけ**(ブリッジが何も撃っていないと保証した断り)。
    /// 他のエラーは届いたかもしれない操作の失敗を含むので撃ち直さない(届いたか分からない操作は撃ち直さない方針)
    static func isRetryableStaleRef(_ error: Error) -> Bool {
        if case DriverError.staleRef? = error as? DriverError { return true }
        return false
    }

    /// システムアラートに遮られ、ブリッジが届けていないと確定した断りか(`DriverError.systemAlertBlocked`)。
    /// 撃ち直すのは登録がある回だけ(呼び手が `systemAlertWatchlist.isWatching` を見る)—— 登録の無いアラートは閉じない
    static func isUndeliveredBySystemAlert(_ error: Error) -> Bool {
        if case DriverError.systemAlertBlocked? = error as? DriverError { return true }
        return false
    }

    /// ブリッジの断りの文言(`InterruptionGuard.message`)が末尾に付ける「iosAlertHandler が自動で閉じる」案内。
    /// 文言の一致では**分岐しない**(判定は登録の有無)。登録済みの利用者に出さないための表示の整形だけ
    static let bridgeAlertHandlerAdvice = "; in a scenario, iosAlertHandler closes it automatically"

    /// システムアラートの断りで落ちるとき、登録(iosAlertHandler)があるのに「自動で閉じる」と案内しない。
    /// 登録済みで落ちたのは、閉じて撃ち直す前に予算(waitSeconds)が尽きた・閉じられなかったとき。種別(`systemAlertBlocked`)は保つ
    /// `canClose` = 撃ち直しの経路がある構成(閉じる手段 = `fallbackDriver`)。無い構成では「時間内に閉じられなかった」と言わない
    /// (閉じる試みを1度もしていない)—— 事実だけ言う
    static func noteAlertRegistration(_ error: Error, registered: Bool, canClose: Bool) -> Error {
        guard registered, case DriverError.systemAlertBlocked(let detail)? = error as? DriverError else { return error }
        let trimmed = detail.replacingOccurrences(of: bridgeAlertHandlerAdvice, with: "")
        guard canClose else {
            return DriverError.systemAlertBlocked(detail: trimmed
                + "; iosAlertHandler is registered, but this mode cannot close system alerts during the step (no XCUITest fallback),"
                + " so the action was not sent again")
        }
        return DriverError.systemAlertBlocked(detail: trimmed
            + "; iosAlertHandler is registered, but it did not close this alert in time, so the action was not sent again")
    }

    /// `executeAction` を、届けていないと確定した断り(staleRef / 登録のあるときの systemAlertBlocked)を受けたときだけ
    /// `step.timeout`(未指定は既定の待ち)の予算内で最初からやり直す。
    /// やり直しはロケータの解決(木の撮り直し)から入るので、新しい木から ref を引き直す
    /// (executor.md「ブリッジの ref は、そのドライバが最後に撮った木の中でだけ有効」)。
    /// **撃っていない操作の記録を巻き戻す**: 入口が `lastInteraction` 等を前のタップの確定に使うので、
    /// 撃たなかった試行が残した記録を次の試行が「前のタップ」として読まないよう、試行の前の値へ戻す。
    /// **やり直しは同じ action の準備の操作(type(replace:) の消去・覆いの下からの持ち上げ・キーボードの向こうへの寄せ)も
    /// 引き直した要素へ撃ち直す**。許容する理由: 断りが出るのは最後に撃つ要求だけで、準備の消去にも同じ撃つ直前の確かめが
    /// 入っている(古い欄を消す前に断られる)・持ち上げと寄せはスクロールの類で、送信・購入のような取り返しのつかない操作ではない
    func executeActionRetryingUndelivered(_ action: String, step: FlowStep, fingerprint: LocatorFingerprint?,
                                       phase: inout PhaseAccumulator) async throws -> StepOutcome {
        let clock = ContinuousClock()
        // 予算の起点は**最初の断りの時刻**(関数の入口ではない)。入口から数えると、`tap` が有効になるのを待った時間
        // (最大 waitSeconds)で予算を使い切り、撃ち直しの1回も撃たずに落ちる。断りが出た時点で撃ち直しの1回は必ず撃てる。
        // 上限: 2回目以降の断りは最初の断りから waitSeconds までしか撃ち直さない(各試行の有効待ちも waitSeconds で打ち切られる)
        var firstRefusalAt: ContinuousClock.Instant?
        var backoff = PollBackoff()
        while true {
            let savedLast = lastInteraction
            let savedAwaiting = tapAwaitingNextTree
            let savedPrevious = previousTapTree
            let savedUnchanged = unchangedEarlierTaps
            let savedTapTarget = lastTapTarget
            do {
                let outcome = try await executeAction(action, step: step, fingerprint: fingerprint, phase: &phase)
                // 座標ドラッグの払いは経路ごとに慣性を立てていなかった(swipePointToPoint / swipeElementToElement の後の tap が
                // 慣性を止めるだけで ok のまま押せない)。分類は StepAction.dragsByCoordinates の1箇所
                if case .passed = outcome.status, StepAction(rawValue: action)?.dragsByCoordinates == true {
                    swipeInertiaPending = true
                    swipeInertiaDirection = nil
                }
                // **操作の直後の解決は、操作より前の古い木を掴みうる**(Android の素取得はキャッシュを返す。Compose は
                // 非同期に骨組みへ差し替わった変化を a11y のキャッシュへ出さず、tap の直後の tap が押せない行を
                // 押せると読んで ok で撃った = 誤った成功。E2EY-CMP 読み込みの状態)。次のロケータ操作の解決の1枚を迂回にする
                if StepAction(rawValue: action)?.mayChangeScreen == true {
                    nextResolveBypassesCache = true
                    assertionReadAfterOwnMove = true
                }
                return outcome
            } catch {
                let blockedByAlert = Self.isUndeliveredBySystemAlert(error)
                    && systemAlertWatchlist.isWatching && fallbackDriver != nil
                guard Self.isRetryableStaleRef(error) || blockedByAlert else {
                    throw Self.noteAlertRegistration(error, registered: systemAlertWatchlist.isWatching,
                                                         canClose: fallbackDriver != nil)
                }
                // 予算を Duration にするのは最初の断りのとき —— `.seconds(Double)` は範囲外で trap する。範囲外の
                // waitSeconds は executeStep の入口(FlowStep.secondsArgumentViolation)が先に断るので、isFinite は二重の備え
                let budget = step.timeout ?? tunables.defaultTimeout
                let refusedFrom = firstRefusalAt ?? clock.now
                guard budget.isFinite, budget > 0, clock.now < refusedFrom.advanced(by: .seconds(budget)) else {
                    throw Self.noteAlertRegistration(error, registered: systemAlertWatchlist.isWatching,
                                                         canClose: fallbackDriver != nil)
                }
                firstRefusalAt = refusedFrom
                lastInteraction = savedLast
                tapAwaitingNextTree = savedAwaiting
                previousTapTree = savedPrevious
                unchangedEarlierTaps = savedUnchanged
                lastTapTarget = savedTapTarget
                if blockedByAlert {
                    // ステップ開始の確認(executeAction の入口の waitOutSystemUI)の後に出たアラート。同じ門で閉じる/待つ:
                    // 登録のボタンが無ければ予算まで待って systemUICovered で落ちる(登録は「次に出る」という予告でもある)
                    if let covered = try await waitOutSystemUI(step: step, phase: &phase) {
                        return StepOutcome(status: covered)
                    }
                    // 閉じられた(消えた)と分かってから立てる = 閉じられずに落ちた回に「撃ち直した」と記録しない
                    noteCodesThisStep.insert(.systemAlertRetried)
                    continue
                }
                noteCodesThisStep.insert(.staleRefRetried)
                let waitStart = clock.now
                try await Task.sleep(for: backoff.nextDelay())
                phase.waitMs += Self.ms(clock.now - waitStart)
            }
        }
    }
}
