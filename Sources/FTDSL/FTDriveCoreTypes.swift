// FTDriveCoreTypes.swift
// FTDriveCore(FTRuntime.swift)の実行で使う値型

import Foundation
import FTCore

/// perform() の内部戻り値。status は既存呼び出し元がそのまま使い、element は exist 系
/// (FTElement.text/value/id)だけが読む
struct PerformResult {
    let status: StepResult.Status
    let element: ElementInfo?
    /// `select` が見えないと判定した要素(StepOutcome.notVisibleSelection)
    var notVisibleSelection: ElementInfo? = nil
    /// findImage / findImages が見つけた要素(StepOutcome.imageMatches)
    var imageMatches: [FindImage.Match]? = nil
    /// ステップの機械可読な注記(StepOutcome.notes)。waitForSettle が「諦めて通った」ことを読む
    var notes: [StepNote] = []
}

extension FTDriveCore {
    /// 条件判定の結果。**閉じた割り込みも運ぶ** —— 不成立の記録に注記を残さないと、
    /// 「本当に無い」のか「覆われていた」のかを読み手が区別できない
    struct CanSelectOutcome {
        let found: Bool
        /// 判定中に閉じた割り込み(検出セレクタの要約と回数)。閉じていなければ nil
        let dismissed: (key: String, count: Int)?
        /// **画面を読めなかった**ときの事実(`found == false` と同時にだけ立つ)。読めなかったことを
        /// 「無い」と言わない —— クラッシュ・接続断・固まりの後に不成立で緑へ抜ける
        var unread: SnapshotReadFailure? = nil
        /// 読めなかったが、**このシナリオが `terminateApp()` で止めたアプリ**なので「無い」として扱った(`unread` は nil)
        var stoppedByScenario = false
    }

    /// canSelect の最後の読みが失敗した理由。kind は**エラーの型**から採る(文言で仕分けない)
    struct SnapshotReadFailure {
        let reason: String
        let kind: StepFailureKind?
    }
}
