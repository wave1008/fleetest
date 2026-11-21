// DSLRunRecords.swift
// シナリオの実行記録の型(ステップ・シーン・シナリオ)。記録を作るのは FTRuntime.swift の FTDriveCore

import Foundation
import FTCore

public struct DSLStepRecord: Sendable {
    public let index: Int
    /// condition / action / expectation(CAE ブロック外は nil)
    public let section: String?
    public let description: String
    public let status: StepResult.Status
    public let file: String
    public let line: Int
    /// レポートの時間列に使う。欠測条件は recordStep のコメント参照
    public let durationMs: Int?
    /// screenshot() コマンドが撮った画像。ScenarioReportWriter がこのステップの直後に埋め込む。
    /// 他コマンドは常に nil(failureScreenshot とは別経路)
    public let screenshotData: Data?
    public let screenshotLabel: String?
    /// `procedure { }` の中で記録したステップ。レポート(.md)は成功・skip を畳む(Shirates の procedure = describe + silent)。
    /// 結果 JSON・イベントには全部残す(事実は省かない)
    public let insideProcedure: Bool
    /// 応答時間計測の記録(計測モードの計測ステップだけ)。t2 は次の計測ステップで後から入る(`applyingReadyUpdate`)
    public var response: ResponseMeasurementRecord?

    public init(index: Int, section: String?, description: String, status: StepResult.Status,
                file: String, line: Int, durationMs: Int? = nil,
                screenshotData: Data? = nil, screenshotLabel: String? = nil, insideProcedure: Bool = false,
                response: ResponseMeasurementRecord? = nil) {
        self.index = index
        self.section = section
        self.description = description
        self.status = status
        self.file = file
        self.line = line
        self.durationMs = durationMs
        self.screenshotData = screenshotData
        self.screenshotLabel = screenshotLabel
        self.insideProcedure = insideProcedure
        self.response = response
    }
}

extension Array where Element == SceneRecordData {
    /// 添字が `stepIndex` のステップへ t2 の確定を当てる(前の scene・区分のステップも探す。無ければ何もしない)
    mutating func applyReadyUpdate(_ update: ResponseReadyUpdate, toStepIndex stepIndex: Int) {
        for s in indices {
            guard let i = self[s].steps.firstIndex(where: { $0.index == stepIndex }),
                  let current = self[s].steps[i].response else { continue }
            self[s].steps[i].response = current.applying(update)
            return
        }
    }
}

/// セレクタの修正提案(自己修復(指紋照合)・フォールバック通過から導出)
public struct FixSuggestion: Sendable {
    /// 強い提案(healed)か弱い提案(passedViaFallback)か
    public let isStrong: Bool
    public let message: String
}

public struct SceneRecordData: Sendable {
    public let number: Int
    public let title: String
    public var steps: [DSLStepRecord] = []
    public var failureScreenshot: Data?
    /// 失敗時証跡スクショが白フレームでエビデンス無効。ScenarioReportWriter が警告表示する。
    public var evidenceBlank: Bool = false
    /// その失敗が前面のシステムアラート(`StepNote.systemAlertPresent`)を伴っていたか。
    /// 白の原因を「凍結」と書くかどうかを `FrozenFrameJudgement` で決めるための材料
    /// (アラート中の in-app スクショはアプリの非アクティブ化で白くなる)
    public var failureUnderSystemAlert: Bool = false
    /// 失敗時点の要素一覧(SnapshotRenderer の1要素1行テキスト)。スクリーンショットからは
    /// `#id` を読み取れないため、直すための情報はこちらが本体(レポートに折りたたみで載せる)
    public var failureElements: String?
    /// 失敗時にアプリより手前にあった**別プロセスの window**(手前が先)。
    /// これが空でないなら「操作がそこに吸われて ✅ のまま何も起きなかった」を第一に疑う
    /// (アプリの a11y ツリーには他プロセスの window が出ないため、要素一覧では気付けない)
    public var failureForegroundWindows: [String] = []
    /// 失敗時にアプリの process が既に無かった(Android のみ。クラッシュの疑い)ことの表示行。
    /// 空 = 言うことなし。中身は appProcessEvidence のクロージャが決める(FTDSL は FTAndroid に
    /// 依存しないため、行の組み立ては FTScenarioRunner 側)
    public var failureAppProcess: [String] = []
    /// 失敗時の絵について言える事実(`FailureScreenshotFacts`)。失敗したステップの NDJSON は絵を撮る前に出ているので、ステップの
    /// `notes` ではなくここに載せる(レポートの絵の直前に1行出す)
    public var failureScreenshotNote: StepNote?

    public var passed: Bool {
        steps.allSatisfy {
            if case .failed = $0.status { return false }
            return true
        }
    }

    /// 「実行されなかった scene」の唯一の定義(手順を1つ以上持ち、全部 skipped)。
    /// 打ち切りで本体を飛ばした scene は失敗した手順を持たず `passed` が true のままなので、
    /// 成功と区別する印はこれ。sceneFinished の `skipped`・結果 JSON・レポートの印はここから導く
    public var isSkipped: Bool {
        !steps.isEmpty && steps.allSatisfy {
            if case .skipped = $0.status { return true }
            return false
        }
    }
}

public struct ScenarioRecordData: Sendable {
    public let id: String
    public let title: String
    public let app: String
    public let platform: String
    /// 実行プロファイル上のデバイス論理名(profiles/runs/ の devices[].name)。orchestrator 経由でない
    /// 実行(--port 直指定等)では取得できず nil
    public let deviceName: String?
    /// 技術識別子(Android: adb serial / iOS: シミュレータ UDID)。取得できなければ nil
    public let deviceIdentifier: String?
    public var scenes: [SceneRecordData] = []
    public var fixSuggestions: [FixSuggestion] = []

    public init(id: String, title: String, app: String, platform: String,
                deviceName: String? = nil, deviceIdentifier: String? = nil,
                scenes: [SceneRecordData] = [], fixSuggestions: [FixSuggestion] = []) {
        self.id = id
        self.title = title
        self.app = app
        self.platform = platform
        self.deviceName = deviceName
        self.deviceIdentifier = deviceIdentifier
        self.scenes = scenes
        self.fixSuggestions = fixSuggestions
    }

    public var passed: Bool { scenes.allSatisfy(\.passed) }
}
