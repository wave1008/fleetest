// run の最後の合否の行。

import Foundation

public enum RunTotalsLine {
    /// --work-queue の子が供給で止まり1本も配られなかった回の行。残りは他のマシンが回すので失敗の数には入らないが、
    /// 「All 0 passed」と言わない。**通常の run は未着手が failed に入るのでここへ来ない**
    /// beforeRun の失敗(1台の run = 自分の失敗・子 = 親の取りやめ)で1本も流さなかった run は、動的な割り振りでなくても「All 0 passed」と言わない。`startCancelReason` があるとき(理由そのものは Run stopped の行が言う)
    public static func noScenarioRan(ranCount: Int, workQueue: Bool, abortReason: String?,
                                     startCancelReason: String?) -> String? {
        if ranCount == 0, startCancelReason != nil {
            // 理由は「❌ Run stopped: <理由>」の行が別に出る(1台の run・子・api run・親で同じ形)。ここは合否の行の代わり
            return "❌ No scenario ran"
        }
        guard ranCount == 0, workQueue, abortReason != nil else { return nil }
        return "⚠️ This machine ran no scenario: the run stopped before one was handed out."
            + " The work queue stays with the other machines"
    }
}
