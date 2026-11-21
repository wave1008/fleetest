// RunSummary.swift
// run の集計結果。オーケストレーション全体は RunOrchestrator.swift

import Foundation

public struct RunSummary: Sendable {
    public let total: Int
    public let failed: Int
    /// 子が対象外を宣言したシナリオ数(`total` に含む。緑でも赤でもない)
    public let skipped: Int
    public var passed: Int { total - failed - skipped }
    /// 実行中に劣化・離脱したワーカーの記録(「label: 理由」)。凍結/消失/連続失敗/接続不能で離脱した
    /// ワーカーを可視化する(復帰した場合も含む)。連鎖失敗の事後診断・レポート表示用。
    public let degradedWorkers: [String]
    /// 結果取り消し+振り直しの監査記録(成功した振り直しは合否記録に痕跡を残さないため、
    /// ここに「どのシナリオを・どのワーカーから・何回目か」を残す)。
    public let freezeRetries: [String]
    /// run 前の blank 判定で sleep/wake 修復により除外を免れたワーカー label(orchestrator は
    /// 関与しない=呼び出し側がワーカー構築時の triage を summary に載せ替える)。
    public let blankRepairs: [String]
    /// run 前の blank 判定で修復不発により除外したワーカー label(同上)。
    public let blankExclusions: [String]
    /// この run の所要時間を性能計測に使ってよいか(`MeasurementValidity.verdict` の結果)。
    /// orchestrator 自身は performanceMode を知らないため常に false/[] を返す —— 呼び手
    /// (ProfileRunner/ApiRunCommand)が blankExclusions 判明後に自分で構築した RunSummary へ埋める。
    public let measurementInvalid: Bool
    public let measurementInvalidReasons: [String]
    /// **FM の実呼び出しが全滅したまま走ったシナリオ数**(呼び出しが1件でもあり、その全部が失敗)。
    /// FM が死んでいると occlusion-guard(`exist` の既定 requireVisible)・`screenLooksLike` が
    /// **黙って素通り**する = その run の緑は「守りが効いた緑」ではない。
    /// **合否は変えない**(FM と無関係な失敗を隠す方が危険)。読み手に劣化を伝えるためだけの数。
    /// 各シナリオの警告は子プロセスの stderr にも出るが、**run のまとめには出ていなかった**ので、
    /// 赤を見るたびに「自分の変更か FM か」を人が切り分ける羽目になっていた
    public let fmUnavailableScenarios: Int
    /// degradedWorkers / freezeRetries と**同じ事実の構造化版**(run.json の workerAnomalies)。
    /// 表示は prose 側、機械的な除外はこちら(片方だけ足さない)
    public let workerAnomalies: [WorkerAnomalyRecord]
    /// `fleetest run --performance` の run か(RunMetaRecord.performanceMode にそのまま焼き込む)。
    /// orchestrator 自身は performanceMode を知らないため常に false を返す —— measurementInvalid と
    /// 同じ理由で呼び手が自分で構築した RunSummary へ埋める
    public let performanceMode: Bool
    /// この run で実際に効いていた 実効設定(RunMetaRecord.effectiveSettings にそのまま焼き込む)。
    /// orchestrator 自身はプロファイルの実効値を知らないため常に nil を返す —— 呼び手
    /// (ProfileRunner/ApiRunCommand)が resolve 済みの値で自分の RunSummary へ埋める
    public let effectiveSettings: EffectiveSettingsRecord?
    /// この run が SIGINT/SIGTERM で中断されたか(RunOrchestrator.requestInterrupt() が
    /// 呼ばれたか)。**呼び手が RunMetaRecord.interrupted へそのまま焼き込む** ——
    /// 「デバイス/ワーカーの問題で赤くなった」と「利用者が止めた」を results insights が
    /// 混同しないため
    public let interrupted: Bool
    /// run を途中で止めた理由(遅延参加の OS の供給が全滅した等。RunMetaRecord.abortReason へ焼き込む)。
    /// nil = 止めていない。**中断(interrupted)とは別の事実** —— 利用者が止めたのではなく、ツールが異常として止めた
    public let abortReason: String?
    /// サービス(scripts/compose.yaml)の起動時の警告(`adb reverse` が張れない 等。英語の文言そのまま)。
    /// orchestrator 自身は知らないので常に空 —— 呼び手(ProfileRunner / ApiRunCommand)が `ServicesSession.warnings` で埋め、
    /// RunMetaRecord.servicesWarnings へ焼き込む
    public let servicesWarnings: [String]
    /// 計測モードの run の識別(RunMetaRecord.responseMeasurement にそのまま焼き込む)。orchestrator は知らないので
    /// 常に nil —— 呼び手(ProfileRunner)が resolve 済みの値で自分の RunSummary へ埋める
    public let responseMeasurement: ResponseMeasurementRunInfo?
    /// beforeRun() が失敗して1本も流さずに終えた(`abortReason` に理由)。中断とも失敗の数とも別の終わり方 = 終了コード 1・
    /// 流さなかったシナリオは未実行として数えず `--failed` の対象にも記録しない(RR-8.4)
    public let beforeRunFailed: Bool
    /// 親の取りやめ(beforeRun の失敗)を受けて1本も流さずに止めた理由(nil = 取りやめを受けていない)。
    /// 中断が先に開始待ちを抜けた run では、後から取りやめの行が届いても立てない
    public let startCancelled: String?

    public init(total: Int, failed: Int, skipped: Int = 0, degradedWorkers: [String] = [],
                freezeRetries: [String] = [],
                blankRepairs: [String] = [], blankExclusions: [String] = [],
                measurementInvalid: Bool = false, measurementInvalidReasons: [String] = [],
                fmUnavailableScenarios: Int = 0,
                workerAnomalies: [WorkerAnomalyRecord] = [],
                performanceMode: Bool = false,
                effectiveSettings: EffectiveSettingsRecord? = nil,
                interrupted: Bool = false,
                abortReason: String? = nil,
                servicesWarnings: [String] = [],
                responseMeasurement: ResponseMeasurementRunInfo? = nil,
                beforeRunFailed: Bool = false,
                startCancelled: String? = nil) {
        self.total = total
        self.failed = failed
        self.skipped = skipped
        self.degradedWorkers = degradedWorkers
        self.freezeRetries = freezeRetries
        self.blankRepairs = blankRepairs
        self.blankExclusions = blankExclusions
        self.measurementInvalid = measurementInvalid
        self.measurementInvalidReasons = measurementInvalidReasons
        self.fmUnavailableScenarios = fmUnavailableScenarios
        self.workerAnomalies = workerAnomalies
        self.performanceMode = performanceMode
        self.effectiveSettings = effectiveSettings
        self.interrupted = interrupted
        self.abortReason = abortReason
        self.servicesWarnings = servicesWarnings
        self.responseMeasurement = responseMeasurement
        self.beforeRunFailed = beforeRunFailed
        self.startCancelled = startCancelled
    }

    /// FM の呼び出しが**全部失敗した**か(呼び出しが1件も無いときは false = 使っていないだけ)
    public static func fmUnavailable(_ usage: FMUsageRecord?) -> Bool {
        guard let usage, usage.calls > 0 else { return false }
        return usage.failures == usage.calls
    }
}
