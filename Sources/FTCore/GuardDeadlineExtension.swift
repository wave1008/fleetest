// GuardDeadlineExtension.swift
// executeAssertExists / executeAssertTextComparison の待ちのループで、締め切りに着いた回に「もう1周」を許す判定。
// 2つのループに同じ形で書かれていた条件を1か所へ置く(DS-24.6「待ちのループ側」)。**判定だけ**を持ち、
// 延長後の副作用(deadline の再設定・注記・`cachedScreenshot = nil`・`continue`)は呼び手が決定ごとに行う。

enum GuardDeadlineExtension {
    /// どの延長をするか。評価順が優先順(①→②→③)
    enum Decision: Equatable {
        /// ① 遅い木の撮り直し(`AssertFreshRetry.arm` が呼び手で続く)
        case freshRetake
        /// ② 起動直後の門が一様な絵を見た回(`first-frame-pending`)。締め切りを1予算ぶん延ばす
        case firstFramePending
        /// ③ 1回目のガード評価が締め切りを跨いだ回(`guard-retaken`)。締め切りを延ばし直近スクショの再利用を切る
        case guardCost
        case none
    }

    /// - mayRetake: `SlowSnapshotBudget.mayRetake` の答え(①②③の全部が前提にする)
    /// - freshRetryArmable: `AssertFreshRetry.canArm(ifSupported:)`(ドライバが迂回に対応し、この待ちで未使用)
    /// - hasLastOcclusion: 直近の評価が覆い(flip)のまま = `lastOcclusion != nil`
    /// - stepTimeoutSeconds: `step.timeout ?? tunables.defaultTimeout`。0 は「初回1回だけ」の意味なので③はしない
    static func decide(mayRetake: Bool, freshRetryArmable: Bool,
                       firstFrameExtended: Bool, firstFrameBlankObserved: Bool,
                       guardCostExtended: Bool, guardEvalCount: Int,
                       hasLastOcclusion: Bool, stepTimeoutSeconds: Double) -> Decision {
        if mayRetake, freshRetryArmable { return .freshRetake }
        if !firstFrameExtended, firstFrameBlankObserved, hasLastOcclusion, mayRetake {
            return .firstFramePending
        }
        if !guardCostExtended, guardEvalCount == 1, hasLastOcclusion, stepTimeoutSeconds > 0, mayRetake {
            return .guardCost
        }
        return .none
    }
}
