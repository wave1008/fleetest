// RunTypes.swift
// run の値型(実行対象・ワーカー・イベント・テスト中の枠)。オーケストレーション全体は RunOrchestrator.swift

import Foundation
import Synchronization

/// 実行対象シナリオ。URL(scenario:// スキーム)が一意キー(呼び出し側の実行レーン管理と互換)
public struct ScenarioRunItem: Identifiable, Sendable {
    public let info: ScenarioInfo
    /// ブロードキャスト実行(`ScenarioDispatch.broadcast`)で「どのレーン(デバイス)のぶんか」。
    /// 通常の共有キューでは nil。**URL のクエリに載る**ので、同じシナリオ ID が N 台で
    /// 同時に走っても (シナリオ × デバイス) が別キーになり、URL で状態を持つ側(表示バッファ・
    /// 稼働集計・キューの再実行回数)が混線しない。`lastPathComponent` は ID のまま
    public let lane: String?
    /// 計測モードの繰り返し(`ResponseMeasurementRepeat.expand`)で「何回目か」(1 始まり)。通常は nil。
    /// lane と同じく URL のクエリに載り、同じシナリオ ID の複数回分が別キーになる。URL を読み戻す側は無い
    public let repeatIndex: Int?
    /// バリアント(シナリオ × バリアントが実行の単位。nil = バリアントの無い run)。lane・repeat と同じく URL のクエリに載る。
    /// **既定値なし**(作り直す所が落とすとバリアントが黙って消える。作り直しは `with(lane:)` / `with(repeatIndex:)` を使う)
    public let variant: String?
    public let url: URL
    public var id: URL { url }
    /// ID × バリアント(並べ替え・割り振り・欠落の照合の鍵。lane・repeat は含めない)
    public var unitKey: ScenarioUnitKey { ScenarioUnitKey(id: info.id, variant: variant) }

    public init(info: ScenarioInfo, lane: String? = nil, repeatIndex: Int? = nil, variant: String?) {
        self.info = info
        self.lane = lane
        self.repeatIndex = repeatIndex
        self.variant = variant
        self.url = Self.url(for: info.id, lane: lane, repeatIndex: repeatIndex, variant: variant)
    }

    /// lane だけ差し替えた item(variant・repeatIndex は引き継ぐ)
    public func with(lane: String?) -> ScenarioRunItem {
        ScenarioRunItem(info: info, lane: lane, repeatIndex: repeatIndex, variant: variant)
    }

    /// repeatIndex だけ差し替えた item(variant・lane は引き継ぐ)
    public func with(repeatIndex: Int?) -> ScenarioRunItem {
        ScenarioRunItem(info: info, lane: lane, repeatIndex: repeatIndex, variant: variant)
    }

    /// シナリオ ID(日本語可)→ 一意キー URL。lane があれば `?lane=<名>`、repeatIndex があれば `repeat=<n>`、
    /// variant があれば `variant=<名>` をクエリに付ける(順は lane・repeat・variant)
    public static func url(for scenarioID: String, lane: String? = nil, repeatIndex: Int? = nil,
                           variant: String?) -> URL {
        let encoded = scenarioID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? "scenario"
        var string = "scenario://run/\(encoded)"
        var query: [String] = []
        if let lane {
            // デバイス名は "(" ")" ":" "&" を含みうるので英数字以外は全部エスケープする
            query.append("lane=" + (lane.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "lane"))
        }
        if let repeatIndex { query.append("repeat=\(repeatIndex)") }
        if let variant { query.append("variant=" + (variant.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "variant")) }
        if !query.isEmpty { string += "?" + query.joined(separator: "&") }
        return URL(string: string) ?? URL(fileURLWithPath: "/scenario")
    }

    /// `url(for:…)` が載せた variant を読み戻す(無ければ nil)。実行ログの見出しが同じ ID の単位を区別するため
    public static func variant(in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "variant" }?.value
    }
}

/// 並列ワーカー定義。platform が一致するシナリオだけをキューから消化する
/// ワーカーを1本ずつ参加させる間隔(秒)。**0 で無効**。
///
/// なぜ要るか: 各シナリオは `condition { launchApp() }` から始まるので、
/// N 台のワーカーを同時に起こすと**最初の launch が N 本同時**に走る。ブリッジ供給側は
/// 「in-app の新規起動は同時2台」に絞ってある(BridgeProvisioner)のに、その数秒後の
/// 本番の launch は無制限、という非対称だった。実測では供給が 2 台ずつ進んだ直後に
/// **10 台中 9 台が画面凍結**し、ワーカー 0 で 24/24 が実行不能になっている。
///
/// **1.5 秒の根拠は「シミュレータの launch がおおむね1〜3秒」**という観測だけで、
/// 凍結率で較正した値ではない —— 効くかどうかは**まだ確かめていない**(凍結の観測は
/// n=1 で、同じ run の別プロファイルは無事だった)。対照実験を安く回せるように
/// `FT_WORKER_STAGGER_SEC` で差し替えられるようにしてある(`0` で一斉起動)。
///
/// **間隔だけでは足りない**(ユーザー指示)。時間は当て推量で、ホストが実際に
/// 空いたことは見ていない —— 供給が長引いた run では飽和したまま次を起こす。もう一つの門
/// (**直近の CPU 使用率が上限未満**)は `WorkerStartGate` にある。`seconds` を 0 にしても
/// CPU の門は残る(こちらを外すのは `FT_WORKER_START_CPU_MAX` ではなく、上限を 100% に
/// 保ったまま「飽和していなければ通る」既定に任せる)。
///
/// **定常のレーン数は変えない**ので、伸びるのは立ち上がりだけ(10 台なら約 13.5 秒)
public enum WorkerStagger {
    public static let defaultSeconds = 1.5

    /// **最初に同時起動してよい台数**(ユーザー決定)。ここを超えた分から
    /// 1本ずつ間隔を空ける —— つまり 1本目と2本目は同時、3本目以降が待つ。
    /// **2 は BridgeProvisioner の「in-app の新規起動は同時2台」と同じ値**で、
    /// 供給と本番の launch で違う上限を持たないために揃えてある。
    /// 10 台なら待つのは 8 本ぶん(既定 1.5s なら約 12 秒)
    public static let simultaneousHead = 2

    public static var seconds: Double {
        guard let raw = ProcessInfo.processInfo.environment["FT_WORKER_STAGGER_SEC"] else {
            return defaultSeconds
        }
        // 不正値は既定へ倒す(黙って 0 = 無効にすると、実験のつもりが対策を外した run になる)
        guard let value = Double(raw), value >= 0, value.isFinite else { return defaultSeconds }
        return value
    }
}

/// @unchecked: `driver`(非 Sendable)は1レーン=1 Task が順に叩く(ホスト側の用途は /status・snapshot の
/// プローブだけ。シナリオ本体は別プロセスが `connection` で直接話す)。期限切れの withDeadline が残した
/// 先行呼び出しとは重なりうるので、driver の実装は並行呼び出しに耐えること(BridgeClient は Mutex)。
public struct RunWorker: @unchecked Sendable {
    /// 表示・イベント上の識別子。形式は2系統ある:
    ///   プロファイル経路 = `makeLabel` の "<デバイス名>(<platform>:<serial|port>)"
    ///   非プロファイル経路(--port/--serial)= "ios:<port>" / "android"
    /// **RunEvent は platform を運ばない**ので、label から platform を戻す必要がある側は
    /// 必ず `RunWorker.platform(fromLabel:)` を使うこと(デバイス名自体が "(" や ":" を含むため、
    /// 素朴な split は壊れる。実際に稼働率集計がデバイス名を platform と誤認した)
    public let label: String
    public let platform: String           // "ios" / "android"
    public let driver: AppDriver          // ウォームアップ・接続確認用
    public let connection: DriverConnection  // サブプロセスへ渡す接続情報
    /// 実行プロファイル上のデバイス論理名(profiles/runs/ の devices[].name)。
    /// ProfileWorkerFactory 経由で構築されたワーカーのみ設定される(fleetest api run の
    /// workersReady イベントの id 構築に使う。--port 等の非プロファイル経路では nil)
    public let logicalName: String?

    /// 既知の platform 名。label から platform を戻すときの照合に使う。
    public static let knownPlatforms: Set<String> = ["ios", "android"]

    /// プロファイル経路の label を組み立てる(解析側の `platform(fromLabel:)` と対。片方だけ変えない)。
    public static func makeLabel(deviceName: String, platform: String, id: String) -> String {
        "\(deviceName)(\(platform):\(id))"
    }

    /// label から platform を戻す。デバイス名が "(" や ":" を含みうるため、
    /// 末尾の "(<platform>:<id>)" を優先して見る。既知の platform 名に一致しない場合は nil。
    public static func platform(fromLabel label: String) -> String? {
        func head(_ text: Substring) -> String {
            String(text.split(separator: ":", maxSplits: 1).first ?? text)
        }
        // プロファイル経路: 末尾の括弧群 "(<platform>:<id>)"
        if label.hasSuffix(")"), let open = label.lastIndex(of: "(") {
            let inner = label[label.index(after: open)..<label.index(before: label.endIndex)]
            let candidate = head(inner)
            if knownPlatforms.contains(candidate) { return candidate }
        }
        // 非プロファイル経路: "ios:<port>" / "android"
        let candidate = head(label[...])
        return knownPlatforms.contains(candidate) ? candidate : nil
    }

    /// label からレーン(= デバイス)の識別子を戻す。プロファイル経路の label は末尾に
    /// "(<platform>:<id>)" を持ち、**iOS の id はブリッジのポートで回復のたびに変わる**ので、
    /// label そのものでレーンを数えると同じデバイスが2レーンになる(リモート2台の run が
    /// 「3 lane(s), 66% busy」と出た。受け手報告)。末尾の括弧群を落とした
    /// デバイス名をレーンの鍵にする。非プロファイル経路("ios:<port>")は label のまま
    public static func laneKey(fromLabel label: String) -> String {
        guard label.hasSuffix(")"), let open = label.lastIndex(of: "("),
              platform(fromLabel: label) != nil, open > label.startIndex
        else { return label }
        return String(label[..<open])
    }

    /// 実行プロファイルが頼んだ iOS のモードと、供給が縮退したときの理由(プロファイル経路の iOS だけ。
    /// 他は nil = 頼んだモード = 実効モード)
    public let requestedMode: String?
    public let modeFallbackReason: String?

    public init(label: String, platform: String, driver: AppDriver, connection: DriverConnection,
                logicalName: String? = nil, requestedMode: String? = nil, modeFallbackReason: String? = nil) {
        self.label = label
        self.platform = platform
        self.driver = driver
        self.connection = connection
        self.logicalName = logicalName
        self.requestedMode = requestedMode
        self.modeFallbackReason = modeFallbackReason
    }

    /// run.json の `workerModes` の1件(iOS だけ)。worker はシナリオの記録の `worker` と同じ文字列(join できる)。
    /// 理由は頼んだモードと実効モードが違うときだけ
    public var modeRecord: WorkerModeRecord? {
        connection.recordedMode.map {
            WorkerModeRecord.resolved(worker: ScenarioRunner.recordingWorker(self), requested: requestedMode,
                                        effective: $0, fallbackReason: modeFallbackReason)
        }
    }
}

/// 実行の進捗イベント。flowURL(scenario:// URL)でシナリオを識別する(呼び出し側はこの URL を
/// キーに実行状態を更新する)
public enum RunEvent: Sendable {
    case runStarted(total: Int, workerLabels: [String])
    /// ウォームアップ完了(コールドブート対策の snapshot 済み)
    case workerReady(worker: String)
    /// 接続不能などでワーカーが離脱した(他ワーカーが残キューを引き継ぐ)
    case workerFailed(worker: String, message: String)
    /// ワーカーの進行状況メッセージ(離脱ではない。ワーカー復帰の進行可視化用。NDJSON では "log")
    case workerLog(worker: String, message: String)
    /// シナリオの結果を取り消して別デバイスへ振り直した(Test Explorer は該当項目を「待機中」へ戻す。
    /// NDJSON では "scenarioRequeued"。契約: vscode-fleetest/src/model.ts ScenarioRequeuedEvent)
    case flowRequeued(worker: String, flowURL: URL, reason: String, attempt: Int, limit: Int)
    case flowStarted(worker: String, flowURL: URL, flowName: String, isDirty: Bool)
    /// scene 開始(ScenarioEvent kind "sceneStarted" 相当)
    case sceneStarted(worker: String, flowURL: URL, scene: Int, sceneTitle: String)
    case step(worker: String, flowURL: URL, result: StepResult)
    /// scene 終了(ScenarioEvent kind "sceneFinished" 相当)。passed = その scene の合否
    case sceneFinished(worker: String, flowURL: URL, scene: Int, sceneTitle: String, passed: Bool, skipped: Bool)
    /// デバッグ実行で一時停止した(index = 次に実行するステップ番号、file/line = その位置)
    case flowPaused(worker: String, flowURL: URL, index: Int, description: String,
                    file: String?, line: Int?)
    /// 自己修復の構造化提案(修復候補の確認 UI 向け)。ログ表示は既存の .step 側で行う。
    /// command = 対象コマンドの description(例: tap "旧セレクタ"。説明提案の生成に使う)
    case fixSuggestion(worker: String, flowURL: URL, scenarioID: String,
                       command: String?, file: String?, line: Int?,
                       oldSelector: String?, newSelector: String?, message: String)
    /// fm: シナリオの FM 呼び出し実測。並列実行では親が scenarioFinished を**再構築**して
    /// stdout へ出すため、ここで運ばないと拡張(モニターの FM グラフ)まで届かない
    /// (結果 JSON は ScenarioHost 内の builder が別経路で受けるので落ちない)
    /// appCrash: scenarioFinished の同名欄(同じ理由で運ぶ)。
    /// notApplicableReason: 子が「この環境では成り立たない」と宣言したシナリオ(passed == true と対)。
    /// 緑でも赤でもない = 表示・集計は skipped に数える。**既定値を置かない**(新しい構築箇所が決める)
    /// resultDiscardedReason: 子は緑で終えたが、親が結果を捨てた理由(`failedFinish`)。`passed` は false で来る。
    /// 表示だけが読み、集計は `passed` のまま(振り直しの上限に達した回は赤として数える)
    case flowFinished(worker: String, flowURL: URL, passed: Bool,
                      reportURL: URL?, fm: FMUsageRecord?, appCrash: AppCrashRecord? = nil,
                      notApplicableReason: String?, resultDiscardedReason: String? = nil)
    /// **ホストの中だけのイベント**(NDJSON・ログには出さない): 直後の flowStarted / flowFinished が**送られた**時刻。
    /// ScenarioTimingTracker は開始・終了とも同じ基準(送り手の時刻)で数える —— 受け取り時刻で数えると、境目の表示の確認が
    /// 終了イベントを保留した分(確認・回復の時間)が実働に入り、片方だけ送り手の時刻にすると読み手の遅れで所要が負になる。
    /// worker は同じ flowURL を複数のワーカーが同時に走らせる broadcast で組を分けるため
    case flowStartedAt(worker: String, flowURL: URL, at: Date)
    case flowEndedAt(worker: String, flowURL: URL, at: Date)
    /// 担当ワーカー不在などで実行できなかった(失敗として数える)
    case flowSkipped(flowURL: URL, reason: String)
    /// もうどのワーカーもシナリオを実行しておらず、残りは録画のクリップ切り出しと後始末だけになった
    /// (録画を1本でも開始できた run で1回だけ。判定は TestingSlots)。NDJSON では "recordingFinalizing"。
    /// 拡張はここから録画タブへ移るまで「録画を編集中」を出す(vscode-fleetest/src/model.ts)
    case recordingFinalizing
    /// passed + failed + skipped == total(skipped = 子が対象外を宣言したシナリオ)
    case runFinished(passed: Int, failed: Int, skipped: Int)
}

/// まだシナリオを実行しうるスロット(参加済みワーカー + 参加待ちの枠)の数。0 になった瞬間が
/// 「テストが全部終わり、録画の切り出し待ちだけが残った」時点。各スロットは**ちょうど1回**閉じる:
/// ワーカーは runWorker の完了経路(切り出しの直前)か、superviseWorker が復帰を諦めたとき。
/// 参加待ちの枠は admit のループ(遅延参加を含む)を抜けたとき —— これが無いと、先に参加した
/// ワーカーが全部終えた瞬間(後続の参加前)に 0 を踏む
actor TestingSlots {
    private var openCount = 0
    private var recordingStarted = false
    private var announced = false

    func open() { openCount += 1 }

    func noteRecordingStarted() { recordingStarted = true }

    /// true = これで全スロットが閉じ、録画を開始できたワーカーが居た(1 run に1回だけ true)
    func close() -> Bool {
        openCount -= 1
        guard openCount == 0, recordingStarted, !announced else { return false }
        announced = true
        return true
    }
}
