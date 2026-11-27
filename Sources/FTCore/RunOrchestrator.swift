// RunOrchestrator.swift
// シナリオ並列実行のオーケストレーション。CLI(fleetest run --port / fleetest api run)が使う。
// シナリオ実行の実体は fleetest-scenarios サブプロセス(ScenarioHost)で、
// FM フックはサブプロセス側が持つ。ワーカーのドライバはウォームアップ・接続確認用。

import Foundation
import Synchronization

/// 1 シナリオの間にステップが報告した snapshot 所要の最大(runWorker の測り直しの門の材料)。
/// onEvent は同期の @Sendable クロージャで、runOne が返る前に全ステップを配り終えるので
/// actor + Task だと読む時点で書き込みが済んでいる保証が無い。`@unchecked Sendable` の根拠は lock
final class SlowestStepSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var maxMs: Int?

    func note(_ ms: Int) {
        lock.lock()
        defer { lock.unlock() }
        maxMs = Swift.max(maxMs ?? ms, ms)
    }

    var value: Int? {
        lock.lock()
        defer { lock.unlock() }
        return maxMs
    }
}

/// 並列ワーカーからの文字列記録の収集(劣化ワーカー・振り直し監査)。run() が summary に畳む。
private actor NoteCollector {
    private var entries: [String] = []
    func add(_ entry: String) { entries.append(entry) }
    func snapshot() -> [String] { entries }
}

private actor AnomalyCollector {
    private var entries: [WorkerAnomalyRecord] = []
    func add(_ entry: WorkerAnomalyRecord) { entries.append(entry) }
    func snapshot() -> [WorkerAnomalyRecord] { entries }
}

/// 並列ワーカーから数える用の素朴なカウンタ
private actor Counter {
    private var value = 0
    func increment() { value += 1 }
    func snapshot() -> Int { value }
}

/// 中断要求の状態(RunOrchestrator.requestInterrupt() が立てる)。並列ワーカーから
/// 読まれるため actor で直列化する(他の Counter 等と同じ理由)
actor RunInterruptFlag {
    private var requested = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    func request() {
        requested = true
        resumeWaiters(with: true)
    }
    func isRequested() -> Bool { requested }
    /// 中断が来たら true・`stopWaiting()` で打ち切られたら false を返す(待ち手を漏らさないため、
    /// 待ちの相手が先に終わった呼び手は必ず stopWaiting を呼ぶ)
    func waitUntilRequested() async -> Bool {
        if requested { return true }
        return await withCheckedContinuation { waiters.append($0) }
    }
    func stopWaiting() { resumeWaiters(with: false) }
    private func resumeWaiters(with value: Bool) {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: value) }
    }
}

/// 1 シナリオあたりの凍結再実行上限。ポイズンシナリオのフリート全滅を防ぐ
/// (2→1: 意図的に NG になるテストがデバイス不調と重なった際の再実行を最小化。ユーザー決定)
let MAX_FREEZE_RETRIES = 1

/// ワーカー・サーキットブレーカ: 同一ワーカーで通常失敗(凍結/消失に該当しない)が連続でこの回数に
/// 達し、**かつその間に別のレーンが通っていたら**、原因不明でも「不調ワーカー」とみなして離脱させ
/// 現シナリオを振り直す(判定は WorkerCircuitBreaker)。凍結/消失の個別プローブで拾えない不良
/// (ブリッジのウェッジ・ANR 連発等)で死んだワーカーへ投げ続ける事故を防ぐ
private let WORKER_FAILURE_CIRCUIT_THRESHOLD = 3

/// 1論理デバイスの復帰試行上限。復帰→即死→復帰の暴走防止
private let MAX_WORKER_REVIVES = 2

/// 参加したレーンの key 集合(broadcast のドレイン文言用)。lease の記帳は RunLeaseLedger
private actor JoinedLaneKeys {
    private var keys: Set<String> = []
    func insert(_ key: String) { keys.insert(key) }
    func snapshot() -> Set<String> { keys }
}

/// runWorker() の離脱理由。.retired は「デバイス使用不能でループを抜けた」場合のみで、
/// superviseWorker の復帰トライへ渡す worker を保持する(キュー消化を再開できる)
private enum WorkerExit {
    case completed(Int)
    case retired(failed: Int, worker: RunWorker)
}

/// シナリオ群をワーカー群で並列消化する。進捗は events(AsyncStream)で配信され、
/// run() の完了時に finish する。イベントはバッファされるため消費開始が遅れても失われない。
public final class RunOrchestrator: Sendable {
    public let events: AsyncStream<RunEvent>
    let continuation: AsyncStream<RunEvent>.Continuation
    private let workers: [RunWorker]
    private let settings: ScenarioExecutionSettings
    private let reportDir: URL
    private let project: TestProject
    /// デバッグ実行(ブレークポイント・ステップ実行)。呼び出し側が単一シナリオ実行時のみ指定する
    private let debug: ScenarioDebugOptions?
    let recorder: RunRecorder?
    /// run 全体で1つ。レーン鍵(論理名)ごとのデバイスセッション。復帰したワーカーも同じ論理名なので
    /// 同じセッションを引き継ぐ(復帰はアプリのデータを消さないので setUpDevice は再実行しない)
    private let deviceSessions = RunDeviceSessionBook()
    /// 仕事を最後まで終えた(離脱しなかった)デバイス。afterAll を走らせる先の候補(終えた順)
    private struct FinishedLane: Sendable {
        let label: String
        let platform: String
        let connection: DriverConnection
        let leaseKey: String?
        /// afterAll の宛先を条件で選ぶ入力(DR-237)
        let traits: DeviceTraits
    }
    private let finishedLanes = LockedValue<[FinishedLane]>([])
    /// run profile の record:true 時のワーカー動画録画(nil = 無効)。VideoRecordingCoordinator.swift
    private let videoRecording: VideoRecordingCoordinator?
    /// recordingFinalizing を出す時点の判定(TestingSlots の宣言参照)
    private let testingSlots = TestingSlots()
    /// Android の画面凍結(blank-screen)判定。FTCore は FTAndroid に依存できない(循環)ため
    /// 実プローブ(AndroidHealthProbe)の注入は呼び出し側(fleetest ターゲット)が行う。
    /// nil(未注入)時は常に false(凍結扱いしない)
    private let isDeviceFrozen: (@Sendable (String) async -> Bool)?
    /// Android デバイスが実行中に到達不能(adb で offline/未検出=プロセス消滅・watchdog 再起動 down 等)に
    /// なったかの判定。凍結(adb 生存・画面のみ死)とは別で、こちらは adb からデバイス自体が消えた状態。
    /// isDeviceFrozen と同じ理由で呼び出し側が注入(未注入時は常に false)
    private let isDeviceUnreachable: (@Sendable (String) async -> Bool)?
    /// xcuitest ブリッジのランナーログ(.fleetest/bridge-<port>.log)の現在サイズ。ログ成長=ランナー生存
    /// の傍証として bridgeUnreachable の busy/ウェッジ判別に使う。ログパスは FTBridgeClient 側の知識
    /// なので isDeviceFrozen と同じ理由で注入。取得不能・非 xcuitest は nil(判別に使わない)
    private let bridgeLogSize: (@Sendable (RunWorker) -> UInt64?)?
    /// ホスト側のランナープロセス(xcuitest の xcodebuild)の生死。nil を返すのは「分からない」
    /// (in-app ブリッジのようにホスト側にプロセスが無い形)。BridgeLiveness.decide の材料
    private let runnerProcessAlive: (@Sendable (RunWorker) -> Bool?)?
    /// 失敗後チェックの /status プローブ 1 回分。isDeviceFrozen と同じ理由で注入(BridgeClient は
    /// FTBridgeClient)。inapp-boost モードは主ポート(in-app)が別アプリのシナリオ中サスペンドされ
    /// 「TCP 受理・HTTP 無応答」になるため、注入側で xcuitest 側ポートを叩く(DS-8.8)。
    /// 未注入時は worker.driver への素朴なプローブにフォールバック
    private let probeBridge: (@Sendable (RunWorker) async -> BridgeProbeOutcome)?
    /// run-lease(RunLease.write/remove、FTBridgeClient)。ワーカーが稼働中のデバイスキーを持ち、
    /// run() 内のハートビートが 5 秒毎に打ち直す。書き手は isDeviceFrozen と同じ理由
    /// (FTCore は FTBridgeClient に依存できない)で fleetest ターゲットが注入
    private let runLeases: RunLeaseLedger
    /// 録画中 lease(RecordingLease.write/remove)。videoRecording?.start(_:) が true
    /// (録画プロセスの起動に成功)を返したキーだけ持つ
    private let recordingLeases: RunLeaseLedger
    /// どちらかの lease の書き手が注入されているか(未注入ならハートビートを起こさない)
    private let hasLeaseWriters: Bool
    /// 実行プロファイル名(run.json の profile と同じ由来。DS-18 の RunProgressRecord.profile)。
    /// orchestrator は解決済みプロファイルの構造を知らないため、呼び出し側が文字列で渡す
    private let profile: String?
    /// run 進捗の書き手(`RunProgressLedger.write` を pid・ディレクトリで束ねたもの)。
    /// isDeviceFrozen 等と同じ理由(FTCore はプロセス起動側の知識を持たない)で fleetest ターゲットが注入
    private let writeRunProgress: (@Sendable (RunProgressRecord) -> Void)?
    private let removeRunProgress: (@Sendable () -> Void)?
    /// 準備中の端末ごとの供給の段階(台帳の supply)。nil = 台帳を書かない経路
    private let supplyProgress: RunSupplyProgress?
    /// 残り見積もり(DS-18.4)の実績を読む件数(シナリオ1本あたり)。
    /// **FTCore は fleetest ターゲットの `LPTOrdering` を参照できない**ため、呼び出し側が
    /// 同じ run の `LPTOrdering.apply` に渡したのと同じ値(`lptHistoryRuns ?? LPTOrdering.defaultHistoryRuns`)
    /// をそのまま渡す —— ETA が LPT の並べ替えと違う窓の実績を読むと、同じ run 内で
    /// 「並び順」と「残り時間」が別々の実績集合を見ることになる
    private let progressHistoryRuns: Int
    /// run() の頭で構築し、その run の間だけ生きる(run をまたいで使い回さない)。
    /// 並行ワーカーが開始する前に一度だけ代入し、以降は読むだけ(TestingSlots 等と違い actor に
    /// しないのは、生成が run() の単一箇所に閉じているため)
    private var progressState: RunProgressState? {
        get { progressStateBox.withLock { $0 } }
        set { progressStateBox.withLock { $0 = newValue } }
    }
    private let progressStateBox = Mutex<RunProgressState?>(nil)
    /// ワーカー離脱(retired)時の後始末(ウェッジしたブリッジプロセスの停止等)。復帰(revive)の
    /// 有無に関係なく離脱の度に必ず呼ぶ — 復帰しない離脱(キュー空・上限到達)で kill を省くと、
    /// ウェッジしたランナーがシミュレータを掴んだまま生き残り、次回 run の新ブリッジと
    /// 2ランナー競合を起こす。isDeviceFrozen と同じ理由で呼び出し側が注入
    private let cleanupRetiredWorker: (@Sendable (RunWorker) async -> Void)?
    /// retired ワーカーの論理デバイス復帰。nil(未注入)なら復帰を試みず即ギブアップ
    /// (呼び出し側がプロファイル経由の場合のみ注入。--port 等の非プロファイル経路では nil)
    private let reviveWorker: (@Sendable (RunWorker) async -> RunWorker?)?
    /// シナリオの境目で「表示が止まっていないか」を確かめる(FTAndroid.DisplayFreezeWatch。判定は DisplayFreezeDetector)。
    /// 確定したレーンは .frozen と同じ扱い(直前の結果を捨てて振り直し・離脱・revive)。isDeviceFrozen と同じ理由で注入
    private let checkLaneDisplay: LaneDisplayCheck?
    /// 描画の状態(白紙・文字消え)で離脱したレーンのデバイスへ、revive の前に回復を1回撃つ(実体は
    /// FTAndroid.ScreenRenderingRecoverer。1台1回の台帳と効いたかの測定はあちらの責務)。nil = 撃たない(離脱と振り直しは行う)
    private let recoverRendering: RenderingRecovery?
    /// run の最後のログに出す「再起動では戻らなかった台」の名前(マシンごとの公表 `UnrecoveredDeviceStore`。run の前の分も含む)
    private let unrecoveredDevices: (@Sendable () -> [UnrecoveredDeviceStore.Entry])?
    /// この run の前の点検で除外した台(`DisplayFreezeWatch.key`)。レーンに入らないが、前の run の残りではない
    private let excludedBeforeRun: (@Sendable () -> Set<String>)?
    /// この run のレーンに入ったデバイスの鍵(run の最後の案内を、この run で使った台とそれ以外に分ける)
    private let usedDeviceKeys = LockedValue<Set<String>>([])
    /// 切り離しの判定帳(`RenderingLaneBook`)。判定と記録を1回のロックで行う
    private let renderingBook = LockedValue<RenderingLaneBook>(RenderingLaneBook())
    /// 描画の状態で離脱し、回復待ちのレーン(レーン key → 状態)。superviseWorker が離脱後に1回だけ引く
    private let renderingPending = LockedValue<[String: DeviceScreenState]>([:])
    /// 切り離しを許すか。broadcast は各レーンが同じセットを1回ずつ回すのが目的で、振り直し先が無い
    private let detachesRendering = LockedValue<Bool>(true)
    /// 各シナリオを子へ渡す直前に、画面に残ったシステムアラートを消す(`ResidualSystemAlertClearing`)。
    /// 戻り値はレーンへ出す1行(nil = 何もしなかった)。**init に既定値を置かない**(呼び手の渡し忘れを
    /// コンパイルで止める。消せない経路は警告だけを返す口を明示して渡す)
    private let clearResidualSystemAlert: (@Sendable (RunWorker) async -> String?)?
    /// 緑で終わったシナリオの直後に、そのレーンの XCUITest ランナーを測り直す(劣化していれば同じポートで
    /// 起動し直す)。引数 = worker・そのシナリオのステップ snapshot 所要の最大(ms。無ければ nil)・
    /// そのレーンへ 1 行出す口。測るか・どう起動し直すかは FTBridgeClient 側の知識なので
    /// isDeviceFrozen と同じ理由で注入。**未注入は合法なので配線漏れはコンパイルで止まらない**
    /// (`RunnerMidRunRecheckTests` が 2 経路を固定)。
    /// 供給時の再利用でしか測っていなかった頃は、run の途中で劣化したレーンが最後まで 1 問 3.7 秒を払った。
    /// **戻り値 `.restarted` = 実際に起動し直した**(WorkerAnomalyRecord kind:"recovered" recovery:.runnerRestart の
    /// 生成に使う。健全・未測定・起動し直し失敗は `.unchanged`)。**`.unusable` = 起動し直した直後でも 1 問にも答えない**:
    /// レーンを離脱させる(復帰の可否は reviveWorker 側の門が決める)
    private let recheckRunner: RunnerRecheck?
    /// シナリオの境目の表示の確認。log はそのレーンの実行ログへ
    /// 第 2 引数はそのプラットフォームの SUT の bundle ID / パッケージ名(確認の home の後に前面へ戻す。分からなければ nil)
    public typealias RenderingRecovery = @Sendable (RunWorker, DeviceScreenState, _ log: @escaping @Sendable (String) -> Void) async
        -> RenderingRecoveryOutcome
    public typealias LaneDisplayCheck = @Sendable (RunWorker, String?, _ log: @escaping @Sendable (String) -> Void) async
        -> LaneDisplayCheckOutcome

    public enum RunnerRecheckVerdict: Sendable, Equatable {
        case unchanged
        case restarted
        case unusable(reason: String)
    }

    public typealias RunnerRecheck =
        @Sendable (RunWorker, Int?, @escaping @Sendable (String) -> Void) async -> RunnerRecheckVerdict
    /// 遅延参加ワーカー(iOS ブリッジ供給待ち)。platforms は「後から必ず来る platform」の宣言で、
    /// これが無いと初期ワーカーに iOS が居ない時点で iOS シナリオが「担当ワーカーなし」で即失敗する。
    /// provider は供給完了時にワーカー群を返す(失敗時は空配列。キューに残った分は run 末尾の
    /// ドレインが「実行できるワーカーがありません」で失敗確定する)。
    /// Android を iOS 供給(壊れたブリッジの置き換え=数十秒)の完了待ちにしないための機構。
    private let lateWorkers: (platforms: Set<String>, provider: @Sendable () async -> [RunWorker])?
    /// プロファイルが宣言した全デバイス(レーン名 = `RunWorker.logicalName`)。供給が済んでも参加しなかったデバイスを
    /// 「試していない台が落ちた」(DR-214)として `ScenarioQueue.laneNeverJoined` へ記帳する元。空 = 記帳しない
    private let plannedLanes: [(lane: String, platform: String)]
    /// `plannedLanes` の台の性質(レーン名で引く。DR-237)。参加しなかった台を結論で「合う台が欠けた」と言うための入力。無い台は読めなかった扱い
    private let plannedTraits: [String: DeviceTraits]
    /// installApp() の親実行ハンドラ(RPC)。nil なら子は --host-install 無しで起動し、
    /// フォールバック(--app-path・明示引数・明示エラー)に委ねる(ScenarioHost.run 参照)。
    /// 呼び出し側(fleetest ターゲット)が InstallHandlerFactory 経由で注入する
    private let installHandler: (@Sendable (RunWorker, String?) async -> (ok: Bool, message: String))?
    /// 実行プロファイルが解決した bundle ID。**platform 別**(ios/android で
    /// 別の ID になりうるので単一値にできない)。シナリオのアプリ
    private let appBundleIDs: [String: String]
    /// 実行プロファイルが解決したアプリ。**platform 別**(appBundleIDs と同じ理由)。
    /// 子の UI フレームワーク判定にパッケージのパスを渡すために持つ —— 実機は simctl で
    /// バンドルを引けないため、これが無いと毎ステップ「不明」に落ちる。
    /// **配るビルドは端末の種別で変わる**ので platform だけでは決まらない
    /// (ResolvedAppTarget.packagePath(physical:))
    private let appTargets: [String: ResolvedAppTarget]
    /// 劣化・離脱したワーカーの収集(summary/レポートの degradedWorkers に載せる)。
    private let degraded = NoteCollector()
    /// 振り直し(結果取り消し+requeue)の監査記録(summary/レポートの freezeRetries に載せる)。
    private let retries = NoteCollector()
    /// 上2つと**同じ事象**の構造化版(run.json の workerAnomalies)。prose と別に持つのではなく
    /// 同じ場所で同時に足す —— 片方だけ足すと「表示には出るが機械可読には無い」に戻る
    private let anomalies = AnomalyCollector()
    /// FM の実呼び出しが全滅したまま走ったシナリオ数(summary の fmUnavailableScenarios)。
    /// **合否には使わない** —— 読み手に「この緑は守りが効いていない」と伝えるための数
    private let fmUnavailable = Counter()
    /// run 全体で通ったシナリオ数(全レーン合計)。ワーカー・サーキットブレーカの「離脱の証拠」
    /// (WorkerCircuitBreaker の冒頭)。自レーンの通過は streak を切るので、streak 中の増分は他レーンの通過
    private let runPasses = Counter()
    /// 子が対象外を宣言したシナリオ数(summary.skipped)。`runPasses` にも数える(レーンは健全)
    private let runSkipped = Counter()
    /// 台の条件に合う台が無く、全台が読めて対象外(緑)で確定した本数(`RunOrchestrator+DeviceRequirements`。summary.skipped に足し、サマリの1行に出す)
    let deviceGapSkipped = LockedValue<Int>(0)
    /// pulled で配られた本数(= この run の total)。shared / broadcast では使わない。
    /// 対象外を親へ返して他のマシンの台へ回し直した分は引く(`resolveNotApplicable`。その結果はこの子のものでなくなる)
    private let handedOut = LockedValue<Int>(0)
    /// 呼び出し側(ローカル `api run`/`run`)が SIGINT/SIGTERM を受けたときに立てる。
    /// 新しいシナリオの配布だけを止める(実行中の子プロセスの SIGTERM は呼び出し側の責務 ——
    /// registerChildProcess 経由でホスト(fleetest ターゲット)が直接持つ登録簿を撃つ。ここに
    /// 二重に持たない)。立った後は通常の完了経路(録画の停止・index.json・lease 解放・
    /// drain)をそのまま通る —— 新規に何かを分岐させない
    let interruptRequested = RunInterruptFlag()
    /// 遅延参加が1台も来なかったときの中止理由(nil = 中止していない)。**中止も interruptRequested を立てて
    /// 配布を止める**が、利用者の中断ではないので、中断のときだけ省く後始末は `stoppedByUser` で見分ける
    let lateJoinAbort = LockedValue<String?>(nil)
    /// 親の取りやめで1本も流さずに止めた理由(`awaitStartGate` で取りやめが中断に勝ったときだけ入る。`lateJoinAbort` にも入る)
    let startCancelled = LockedValue<String?>(nil)
    /// pulled の配り手(中断で待ちを解く相手)。requestInterrupt と run の設定のどちらが先でも解けるよう、中断済みかを一緒に持つ
    private let pullInterrupt = LockedValue<(source: (any ScenarioPullSource)?, interrupted: Bool)>((nil, false))
    /// ScenarioHost.run(registerChildProcess:) への素通し(呼び出し側が実行中の子を SIGTERM
    /// できるようにする登録口。FTCore は fleetest ターゲットの型を知らないので closure で受ける)
    private let registerChildProcess: (@Sendable (Process) -> @Sendable () -> Void)?
    /// 連続失敗の台帳(LaneFailureStreakStore)の置き場 = リポジトリの `.fleetest/`。nil = 引き継がない
    private let laneStreakStateDir: URL?
    /// シナリオごとの「最後に通ってから落ちたデバイス」(ScenarioFailureWitnesses)。別のデバイスでも落ちたシナリオの赤は
    /// ブレーカに数えない。置き場は laneStreakStateDir(nil なら run の中だけ)
    private let failureWitnesses: LockedValue<ScenarioFailureWitnesses>
    /// 人のライブ操作の台帳の置き場(`ScenarioRecording.humanOperationsStateDir` へ運ぶ)。nil = 引かない
    private let humanOperationsStateDir: URL?

    /// ワーカー離脱を通知(イベント yield + 劣化ワーカー収集)を1箇所に集約する。
    /// **cause は呼び出し側が型から決めて渡す**(message の文字列を後から解析しない。既定値を置かない =
    /// 新しい呼び出し元の渡し忘れをコンパイルで止める)
    private func reportWorkerFailed(_ worker: RunWorker, _ message: String,
                                    cause: WorkerAnomalyCause?) async {
        continuation.yield(.workerFailed(worker: worker.label, message: message))
        await degraded.add("\(worker.label): \(message)")
        await anomalies.add(WorkerAnomalyRecord(
            kind: "degraded", worker: Self.workerID(worker), label: worker.label, reason: message,
            cause: cause))
    }

    /// 連続失敗の台帳の置き場。注入が無い・鍵が無い(論理名なし)ときは nil = 引き継がない
    private func laneStreakKey(_ key: String?) -> (dir: URL, key: String)? {
        guard let dir = laneStreakStateDir, let key else { return nil }
        return (dir, key)
    }

    /// ブレーカに数えた失敗の直後に台帳へ写す。**中断で終わったシナリオの失敗は持ち越さない**
    /// (デバイスの性質ではない)。**trip でも消さない**(消すのは通過だけ)—— 消すと 1 run に 2 件しか
    /// 受け取らない不調機(ロック画面のままだったエミュレータ)は次の run で 0 から数え直し、2 run に 1 回しか外れない。
    /// 復活したレーンは最初の失敗で再び離脱し、直っていれば最初の通過で台帳が消える
    private func persistStreak(_ breaker: WorkerCircuitBreaker, key: String?) async {
        guard let s = laneStreakKey(key), await !stoppedByUser() else { return }
        LaneFailureStreakStore.save(stateDir: s.dir, key: s.key, scope: project.name,
                                    consecutiveFailures: breaker.consecutiveFailures)
    }

    /// 通過・失敗を ScenarioFailureWitnesses に写し、失敗はブレーカに数えるかを返す。鍵(論理名)が無いレーンは常に数える。
    /// 中断で終わった失敗は記録しない(persistStreak と同じ)
    private func witnessOutcome(unit: ScenarioUnitKey, worker key: String?, passed: Bool) async -> Bool {
        guard let key, await !stoppedByUser() else { return true }
        // 書き込みも錠の中(錠の外で写しを書くと、後から書いたレーンの古い写しが新しい記録を上書きする)
        return failureWitnesses.withLock { w -> Bool in
            let counts: Bool
            if passed { w.recordPass(unit: unit, worker: key); counts = true }
            else { counts = w.recordFailure(unit: unit, worker: key) }
            if let dir = laneStreakStateDir { w.save(stateDir: dir, scope: project.name) }
            return counts
        }
    }

    /// 遅延参加の OS の供給が全滅したときの中止理由(**唯一の定義**。--debug の逐次経路も同じ文で止める)
    public static func lateJoinAbortReason(platforms: Set<String>) -> String {
        let names = platforms.sorted().map { $0 == "ios" ? "iOS" : $0 == "android" ? "Android" : $0 }
            .joined(separator: "/")
        return "no \(names) device joined the run (every \(names) device dropped out during supply"
            + " — the reason for each is in the lines above)"
    }

    /// 持ち越しは前の run からだけ(同じ run で復帰したレーンは `runWorker` が台帳を消して 0 から数え直す)
    static func carriedNote(_ carried: Int) -> String {
        carried > 0 ? " (including \(carried) carried over from earlier runs)" : ""
    }

    /// シナリオ記録(ScenarioRunRecord.worker)と join できる形。論理名が無い経路では nil
    public static func workerID(_ worker: RunWorker) -> String? {
        worker.logicalName.map { "\(worker.platform):\($0)" }
    }

    public init(project: TestProject, workers: [RunWorker], settings: ScenarioExecutionSettings,
                reportDir: URL,
                debug: ScenarioDebugOptions? = nil, recorder: RunRecorder? = nil,
                recordingConfig: VideoRecordingConfig? = nil,
                isDeviceFrozen: (@Sendable (String) async -> Bool)? = nil,
                isDeviceUnreachable: (@Sendable (String) async -> Bool)? = nil,
                bridgeLogSize: (@Sendable (RunWorker) -> UInt64?)? = nil,
                runnerProcessAlive: (@Sendable (RunWorker) -> Bool?)? = nil,
                probeBridge: (@Sendable (RunWorker) async -> BridgeProbeOutcome)? = nil,
                writeRunLease: (@Sendable (String) -> Void)? = nil,
                removeRunLease: (@Sendable (String) -> Void)? = nil,
                writeRecordingLease: (@Sendable (String) -> Void)? = nil,
                removeRecordingLease: (@Sendable (String) -> Void)? = nil,
                profile: String? = nil,
                writeRunProgress: (@Sendable (RunProgressRecord) -> Void)? = nil,
                removeRunProgress: (@Sendable () -> Void)? = nil,
                supplyProgress: RunSupplyProgress? = nil,
                progressHistoryRuns: Int,
                clearResidualSystemAlert: (@Sendable (RunWorker) async -> String?)?,
                cleanupRetiredWorker: (@Sendable (RunWorker) async -> Void)? = nil,
                reviveWorker: (@Sendable (RunWorker) async -> RunWorker?)? = nil,
                checkLaneDisplay: LaneDisplayCheck? = nil,
                recoverRendering: RenderingRecovery? = nil,
                unrecoveredDevices: (@Sendable () -> [UnrecoveredDeviceStore.Entry])? = nil,
                excludedBeforeRun: (@Sendable () -> Set<String>)? = nil,
                recheckRunner: RunnerRecheck? = nil,
                lateWorkers: (platforms: Set<String>, provider: @Sendable () async -> [RunWorker])? = nil,
                plannedLanes: [(lane: String, platform: String)] = [],
                plannedTraits: [String: DeviceTraits] = [:],
                installHandler: (@Sendable (RunWorker, String?) async
                                  -> (ok: Bool, message: String))? = nil,
                appBundleIDs: [String: String] = [:],
                appTargets: [String: ResolvedAppTarget] = [:],
                registerChildProcess: (@Sendable (Process) -> @Sendable () -> Void)? = nil,
                laneStreakStateDir: URL? = nil,
                humanOperationsStateDir: URL? = nil) {
        self.laneStreakStateDir = laneStreakStateDir
        self.failureWitnesses = LockedValue(laneStreakStateDir.map {
            ScenarioFailureWitnesses.load(stateDir: $0, scope: project.name) } ?? ScenarioFailureWitnesses())
        self.humanOperationsStateDir = humanOperationsStateDir
        (self.events, self.continuation) = AsyncStream.makeStream(of: RunEvent.self)
        self.workers = workers
        self.settings = settings
        self.reportDir = reportDir
        self.project = project
        self.debug = debug
        self.recorder = recorder
        self.videoRecording = recordingConfig.map {
            VideoRecordingCoordinator(config: $0, probeHardwareEncoder: { await HardwareEncoderProbe.check() },
                                      liveStreamsActive: { LiveEncodeStreams.anyActive() })
        }
        self.isDeviceFrozen = isDeviceFrozen
        self.isDeviceUnreachable = isDeviceUnreachable
        self.bridgeLogSize = bridgeLogSize
        self.runnerProcessAlive = runnerProcessAlive
        self.probeBridge = probeBridge
        self.runLeases = RunLeaseLedger(write: writeRunLease, remove: removeRunLease)
        self.recordingLeases = RunLeaseLedger(write: writeRecordingLease, remove: removeRecordingLease)
        self.hasLeaseWriters = writeRunLease != nil || writeRecordingLease != nil
        self.profile = profile
        self.writeRunProgress = writeRunProgress
        self.removeRunProgress = removeRunProgress
        self.supplyProgress = supplyProgress
        self.progressHistoryRuns = progressHistoryRuns
        self.cleanupRetiredWorker = cleanupRetiredWorker
        self.reviveWorker = reviveWorker
        self.checkLaneDisplay = checkLaneDisplay
        self.recoverRendering = recoverRendering
        self.unrecoveredDevices = unrecoveredDevices
        self.excludedBeforeRun = excludedBeforeRun
        self.clearResidualSystemAlert = clearResidualSystemAlert
        self.recheckRunner = recheckRunner
        self.lateWorkers = lateWorkers
        self.plannedLanes = plannedLanes
        self.plannedTraits = plannedTraits
        self.installHandler = installHandler
        self.appBundleIDs = appBundleIDs
        self.appTargets = appTargets
        self.registerChildProcess = registerChildProcess
    }

    /// 呼び出し側の SIGINT/SIGTERM ハンドラから呼ぶ。**新しいシナリオの配布を止めるだけ**
    /// (実行中の子プロセスの SIGTERM は呼び出し側が registerChildProcess の登録簿で行う ——
    /// ここでは二重に持たない)。立てた後は run() の通常の完了経路(録画停止・lease 解放・
    /// drain・summary)がそのまま走る
    /// 利用者の中断(SIGINT/SIGTERM)か。遅延参加の中止は配布を止めるだけで、中断のときに省く後始末(片付け・
    /// afterAll・表示の停止の確認・連続失敗の記録)は省かない
    private func stoppedByUser() async -> Bool {
        await interruptRequested.isRequested() && lateJoinAbort.withLock { $0 } == nil
    }

    /// beforeRun の書き込みを run メモへ入れる(1台のマシンだけの run。`run` を呼ぶ前に)
    public func seedRunMemo(_ ops: [RunMemoOp]) { deviceSessions.shared.seedRunMemo(ops) }

    /// この run の run メモの今の値(afterRun が読む。`run` が終わった後に)
    public func runMemoSnapshot() -> [String: [String]] { deviceSessions.shared.runMemoSnapshot() }

    public func requestInterrupt() {
        // 待っているロックの要求を失敗にし、以後の新しい要求もすぐ失敗にする(RR-8.5)
        deviceSessions.shared.locks.interrupt()
        Task { await interruptRequested.request() }
        let source = pullInterrupt.withLock { p -> (any ScenarioPullSource)? in
            p.interrupted = true
            return p.source
        }
        source?.stopWaiting()
    }

    private func deviceUnreachable(_ serial: String) async -> Bool {
        guard let probe = isDeviceUnreachable else { return false }
        return await probe(serial)
    }

    /// 死活確認系の await に期限を切る。ウェッジしたブリッジは「接続は受けるが応答しない」ため、
    /// BridgeClient の既定タイムアウトに任せると status 確認だけで数分止まり run 全体が凍結する
    /// (実測: ウェッジ機への status で run が 5 分以上アイドル固着)。
    ///
    /// **withTaskGroup は使わない**: 構造化並行はスコープ終端で全子タスクの完了を待つため、
    /// op(URLSession)がキャンセルに即応しないと cancelAll しても遅い方を待ち続けてハングする。
    /// ここは「先に終わった方で即確定・遅い方は待たない」レースにする(継続を一度だけ resume。
    /// 期限側が勝ったら op はキャンセルだけして放置=最終的に URLSession の timeout で自然消滅)。
    private func withDeadline<T: Sendable>(
        seconds: Double, _ op: @escaping @Sendable () async throws -> T
    ) async -> T? {
        await DeadlineRace.first(seconds: seconds, op)
    }

    /// /status 1回分(5s 期限)。refused=ポート LISTEN なし(プロセス死亡)、silent=期限内無応答。
    /// probeBridge(注入)があればそちら(inapp-boost モードの suspend 回避で xcuitest 側ポートを叩く)。
    /// 未注入時は worker.driver に対する素朴なプローブ
    private func probeBridgeOnce(_ worker: RunWorker) async -> BridgeProbeOutcome {
        if let probeBridge { return await probeBridge(worker) }
        let result = await withDeadline(seconds: 5) { () -> BridgeProbeOutcome in
            do {
                let status = try await worker.driver.status()
                // 到達できても相手が別のデバイスなら「接続不能」と同じ扱い(奪った側は健全に答える)
                if worker.platform == "ios", let port = worker.connection.port,
                   case .mismatch(let detail) = BridgeIdentityCheck.verdict(
                       expected: BridgeIdentityCheck.expected(for: worker.connection, probedPort: port),
                       status: status, remedy: BridgeIdentityCheck.runLaneRemedy) {
                    return .hijacked(detail: detail)
                }
                return .ok
            }
            catch DriverError.bridgeConnectionRefused { return .refused }
            catch { return .silent }
        }
        return result ?? .silent
    }

    /// iOS ワーカーの失敗後チェック。1 周ごとの判定は `BridgeLiveness.decide`(純粋関数)。
    /// 観察窓は 60s —— 失敗直後は AX 飽和で健全ブリッジも数十秒 /status に応答しない
    /// (プレフライト不採用と同じ教訓。短い期限は必ず誤検知する)。
    /// 不達と判定したときの事実(離脱理由に写す)。**戻り値で運ぶ** —— レーンが並行して呼ぶので
    /// オーケストレータのメンバー経由だと別レーンの判定が上書き・消去する
    private enum BridgeUnreachableVerdict {
        case identityMismatch(String)
        case unreachable(detail: String?)
    }

    /// nil = 到達できる
    private func bridgeUnreachable(_ worker: RunWorker) async -> BridgeUnreachableVerdict? {
        let deadline = Date().addingTimeInterval(BRIDGE_PROBE_OBSERVE_SECONDS)
        var lastSize = bridgeLogSize?(worker)
        let hasLogSignal = lastSize != nil  // in-app 等ホスト側ログが無い場合は窓いっぱい /status のみで判定
        var lastGrowth = Date()
        while true {
            let probe = await probeBridgeOnce(worker)
            if hasLogSignal, let size = bridgeLogSize?(worker) {
                if let prev = lastSize, size > prev { lastGrowth = Date() }
                lastSize = size
            }
            switch BridgeLiveness.decide(
                probe: probe, host: worker.connection.host,
                runnerProcessAlive: runnerProcessAlive?(worker),
                logSilentSeconds: hasLogSignal ? Date().timeIntervalSince(lastGrowth) : nil,
                logSilenceThreshold: BRIDGE_PROBE_LOG_SILENCE_SECONDS,
                windowExpired: Date() >= deadline) {
            case .reachable:
                return nil
            case .unreachable(let detail):
                if case .hijacked = probe, let detail { return .identityMismatch(detail) }
                return .unreachable(detail: detail)
            case .keepObserving:
                break
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func deviceFrozen(_ serial: String) async -> Bool {
        guard let probe = isDeviceFrozen else { return false }
        return await probe(serial)
    }

    /// - dispatch: `.shared`(既定。platform 別の共有キュー)/ `.pulled`(キューは空で始まり、空いたワーカーが
    ///   外の配り手から1本ずつもらう。total は配られた本数)/ `.broadcast`(レーン別キュー。
    ///   `fleetest run --broadcast`)。**違うのはキューの切り方と、ワーカーがどのキューを
    ///   取るかだけ** —— スタッガ・CPU 門・復帰・lease・録画・ドレインは同じ経路を通る
    /// - startGate: 親の開始の行を待つ関数(nil = 待たない)。詳細は `awaitStartGate`
    public func run(items: [ScenarioRunItem], defaultPlatform: String,
                    dispatch: ScenarioDispatch = .shared,
                    startGate: (@Sendable () async -> WorkQueueProtocol.StartSignal)? = nil) async -> RunSummary {
        // run 全体のロック(RR-8.5): ソースの走査・待ちの上限(この run の対象の最長の scenarioTimeout)・run ログへの出し口
        let lockLog = continuation; defer { deviceSessions.shared.locks.stop() }
        deviceSessions.shared.locks.configure(project: project, scenarioTimeouts: items.map(\.info.scenarioTimeout),
                                              settingsTimeout: settings.scenarioTimeout) { lockLog.yield(.workerLog(worker: "run", message: $0)) }
        // Vision の特徴量の救済用の補助プロセス(run / api run / リモートのランナー機の run が共有する唯一の入口。
        // デバッグ実行では起こさない)。見本を持たないプロジェクトでは何も起こらない(VisionHelperHost)
        if case .broadcast = dispatch { detachesRendering.withLock { $0 = false } }
        let visionHelper = debug == nil ? VisionHelperHost.acquire(project: project) : nil
        defer { visionHelper?.release() }
        var failed = 0
        var isPulled = false
        /// キューの key(shared = platform / broadcast = レーン key)。ワーカーがどれを取るかは queueKey
        let queues: [String: ScenarioQueue]
        let total: Int
        let queueKey: @Sendable (RunWorker) -> String
        /// ドレイン(残ったまま終わった item)の記録に載せる (platform, worker, 理由)
        let drainInfo: (String, Bool) -> (platform: String, worker: String?, reason: String)
        /// 実際にキューへ乗る(= いつか scenarioStarted される)シナリオの鍵の多重集合。
        /// 残り見積もり(DS-18.4)の未着手初期値。**即スキップ分(担当ワーカーなし)は
        /// 含めない** —— どのレーンにも一生取られないので、含めると見積もりが下がりきらないまま残る
        var runnableScenarios: [RunProgressEstimate.ScenarioKey] = []
        let isSharedDispatch: Bool
        if case .broadcast = dispatch { isSharedDispatch = false } else { isSharedDispatch = true }
        switch dispatch {
        case .shared:
            let grouped = Dictionary(grouping: items) { $0.info.platform ?? defaultPlatform }
            // 遅延参加分の platform も含める(含めないと初期ワーカー不在の platform のシナリオが
            // 供給完了を待たず「担当ワーカーなし」で即失敗する)
            let workerPlatforms = Set(workers.map(\.platform)).union(lateWorkers?.platforms ?? [])

            // 担当ワーカーのない platform のシナリオは即スキップ(失敗扱い)
            for (platform, list) in grouped where !workerPlatforms.contains(platform) {
                for item in list {
                    let reason = "no worker available (platform: \(platform))"
                    continuation.yield(.flowSkipped(flowURL: item.url, reason: reason))
                    recorder?.recordSkipped(unit: item.unitKey, title: item.info.title,
                                            platform: platform, worker: nil, reason: reason)
                }
                failed += list.count
            }
            let runnable = grouped.filter { workerPlatforms.contains($0.key) }
            queues = runnable.mapValues { ScenarioQueue($0) }
            total = items.count
            queueKey = { $0.platform }
            drainInfo = { platform, _ in (platform, nil, "no usable workers") }
            runnableScenarios = runnable.flatMap { platform, list in
                list.map { RunProgressEstimate.ScenarioKey(scenarioID: $0.info.id, variant: $0.variant, platform: platform) }
            }
        case .pulled(let source):
            isPulled = true
            let alreadyInterrupted = pullInterrupt.withLock { p -> Bool in
                p.source = source
                return p.interrupted
            }
            if alreadyInterrupted { source.stopWaiting() }
            let grouped = Dictionary(grouping: items) { $0.info.platform ?? defaultPlatform }
            let workerPlatforms = Set(workers.map(\.platform)).union(lateWorkers?.platforms ?? [])
            // shared と違い、担当ワーカーのない platform のシナリオを失敗にしない —— 配られていない
            // シナリオはこの子のものではない(他のマシンが回す)。配り手はその platform を聞かれない
            queues = grouped.filter { workerPlatforms.contains($0.key) }.reduce(into: [:]) { result, entry in
                var catalog: [ScenarioUnitKey: [ScenarioRunItem]] = [:]
                for item in entry.value { catalog[item.unitKey, default: []].append(item) }
                result[entry.key] = ScenarioQueue(pulled: ScenarioQueue.PullState(
                    source: source, platform: entry.key, catalog: LockedValue(catalog),
                    onHandOut: { [weak self] _ in
                        self?.handedOut.withLock { $0 += 1 }
                        await self?.progressState?.growTotal()
                    },
                    onUnknownID: { [weak self] unit in
                        self?.continuation.yield(.workerLog(
                            worker: "run", message: "work queue handed out an unknown scenario id: \(unit)"))
                    }))
            }
            total = 0
            queueKey = { $0.platform }
            drainInfo = { platform, _ in (platform, nil, "no usable workers") }
            // 残り見積もりは出さない(自分の持ち分が分からない)
        case .broadcast(let lanes):
            let plan = BroadcastPlan.make(items: items, lanes: lanes)
            for item in plan.unassigned {
                let platform = item.info.platform ?? defaultPlatform
                let reason = "no device available (platform: \(platform))"
                continuation.yield(.flowSkipped(flowURL: item.url, reason: reason))
                recorder?.recordSkipped(unit: item.unitKey, title: item.info.title,
                                        platform: platform, worker: nil, reason: reason)
                failed += 1
            }
            queues = plan.queues.mapValues { ScenarioQueue($0) }
            total = plan.total
            queueKey = { BroadcastPlan.laneKey(of: $0) }
            let lanePlatform = Dictionary(lanes.map { ($0.key, $0.platform) },
                                          uniquingKeysWith: { first, _ in first })
            drainInfo = { key, joined in
                let platform = lanePlatform[key] ?? "?"
                // デバイスごとの事実だけ言う(never joined = 供給・triage で落ちて1度も参加しなかった /
                // joined = 参加したが離脱し、復帰できないまま自分のぶんが残った)
                return (platform, "\(platform):\(key)",
                        joined ? "device \(key) dropped out and could not be revived"
                               : "device \(key) never joined the run")
            }
            // broadcast は1レーン1キュー = plan.queues のまま(shared と違い platform で
            // まとめ直さない)。cross-platform 項目(item.info.platform == nil)は各対象レーンの
            // platform で複数回計上される —— 実際に各レーンで1回ずつ走るジョブなので正しい
            runnableScenarios = plan.queues.flatMap { key, list in
                list.map { RunProgressEstimate.ScenarioKey(
                    scenarioID: $0.info.id, variant: $0.variant, platform: lanePlatform[key] ?? defaultPlatform) }
            }
        }
        /// broadcast のドレイン文言用(参加したレーンの key)。shared では使わない
        let joinedKeys = JoinedLaneKeys()

        // run 進捗の記帳(DS-18)。**total はここで確定した値のまま動かさない**
        // (再キュー・失敗で変えない。RunProgressRecord.total の宣言参照)
        if writeRunProgress != nil || removeRunProgress != nil {
            // 残り見積もり(DS-18.4)。読むのは run 開始時に1回だけ。LPTOrdering.apply と同じ実績源
            // (RunResultsStore.scanRecords → LPTScheduler.durations)だが **machine 優先はしない**
            // (preferringMachine 無し。手元の run の見積もりに他機の実績を混ぜるかは別の設計判断)
            let resultsDir = RunResultsStore.resultsDir(projectRoot: project.rootURL)
            let since = RunResultsStore.lptHistorySince()
            // LPTOrdering.apply と同じ下限(0/負値を渡されても「実績なし」に安全側で倒れる。
            // FleetRunner.runSplit の historyRuns 節と同じ)
            let records = RunResultsStore.scanRecords(
                resultsDir: resultsDir, since: since,
                maxObservationsPerScenario: max(1, progressHistoryRuns))
            let durations = LPTScheduler.durations(from: records)
            let estimateTable = RunProgressEstimate.estimateTable(
                durations: durations, scenarios: runnableScenarios)

            progressState = RunProgressState(
                pid: ProcessInfo.processInfo.processIdentifier,
                runID: recorder?.runID, runGroup: recorder?.runGroup,
                issuer: LocalConfig.resolveIssuerId(), project: project.name, profile: profile,
                startedAt: Date(), total: total,
                estimates: estimateTable, pendingScenarios: runnableScenarios,
                supply: supplyProgress, write: writeRunProgress, remove: removeRunProgress)
        }

        continuation.yield(.runStarted(total: total, workerLabels: workers.map(\.label)))

        // run-lease/recording-lease ハートビート: mtime を stalenessSeconds(15s)以内に保つため
        // 5s 毎に再書き込み。録画は videoRecording?.start(_:) が成功した時だけ recordingLeases に
        // 積まれる(record:false の run では何も積まれず書き込みも起きない)。
        // **打ち直しは RunLeaseLedger の中で行う**(外でキー一覧を取ってから書くと release と競合する)
        let heartbeat: Task<Void, Never>? = hasLeaseWriters
            ? Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled, let self else { return }
                    await self.runLeases.heartbeat()
                    await self.recordingLeases.heartbeat()
                }
            } : nil

        await awaitStartGate(startGate)

        failed += await withTaskGroup(of: Int.self, returning: Int.self) { group in
            // **ワーカーは一斉に起こさない**。各シナリオは `condition { launchApp() }`
            // から始まるので、N 本のワーカーを同時に積むと**最初の launch が N 本同時**に走る。
            // ブリッジ供給側は「in-app の新規起動は同時2台」に絞ってあるのに、その数秒後の
            // 本番の launch は無制限、という非対称だった(実測: 供給は 2 台ずつ進んでいたのに
            // 直後に 9/10 台が画面凍結)。**定常のレーン数は変えない**ので、遅くなるのは
            // 立ち上がりだけ(**先頭 2 本は同時**・3 本目から間隔と CPU の門を通る)。
            // 判定は WorkerStartGate に置いてある(間隔だけでは「本当に空いたか」を見ていないため、
            // **直近の CPU 使用率が上限未満**であることも要求する)。
            // ここで await しても**既に積んだ子タスクは止まらない**(下の遅延参加のコメントと同じ)
            let cpuSampler = CPUSampler(logFailure: { _ in })
            // CPUSampler は**初回だけ必ず nil**(前回サンプルが無く差分が取れない)。ここで
            // 1回捨てておくと、3本目が門に来た時点で既に有効な値が返る
            _ = cpuSampler.sample()
            let startGate = WorkerStartGate(
                sampleCPU: { cpuSampler.sample() },
                sleep: { try? await Task.sleep(for: .seconds($0)) })
            func admit(_ worker: RunWorker, _ queue: ScenarioQueue) async {
                // 実効モードを run.json へ(初期も遅延参加もここを通る = 参加したデバイスだけが載る)
                if let record = worker.modeRecord { recorder?.recordWorkerMode(record) }
                await startGate.waitForTurn(log: { [continuation] message in
                    continuation.yield(.workerLog(worker: worker.label, message: message))
                })
                await testingSlots.open()
                await queue.laneJoined(ScenarioQueue.lane(of: worker), kind: worker.deviceKind, traits: worker.effectiveTraits)
                group.addTask {
                    let failed = await self.superviseWorker(worker, queue: queue)
                    // 束ねたクラスの残りは別のレーンへ移さず実行しなかった赤にする(中断のときはドレインが記録する)
                    let orphans = await queue.laneEnded(ScenarioQueue.lane(of: worker), orphaning: await !self.stoppedByUser())
                    return failed + self.recordNotRun(orphans, worker: worker) {
                        ClassPlacementRules.orphanReason(
                            placement: $0.info.placement ?? .singleDevice,
                            className: ClassPlacementRules.className(of: $0.info.id),
                            lane: worker.logicalName ?? worker.label)
                    }
                }
            }
            // 参加待ちの枠(下の admit ループ・遅延参加を抜けたら閉じる)
            await testingSlots.open()
            // キューが無いワーカー(shared: その platform のシナリオが無い / broadcast: レーンの
            // ぶんが 0 本、または計画に無いデバイス)は参加させない
            // 供給が済んだ OS(遅延参加でない)で、宣言されたのに参加しない台は、最初のワーカーを走らせる前に落ちた台として記帳する
            // (走らせてからだと、最初の対象外の判定に間に合わず「全部試した」と読まれて緑で確定する)
            await Self.registerNeverJoined(planned: plannedLanes.filter { !(lateWorkers?.platforms.contains($0.platform) ?? false) },
                                           joinedLanes: Set(workers.map { ScenarioQueue.lane(of: $0) }), queues: queues, isShared: isSharedDispatch, traits: plannedTraits)
            for worker in workers {
                guard let queue = queues[queueKey(worker)] else { continue }
                await joinedKeys.insert(queueKey(worker))
                await admit(worker, queue)
            }
            // 遅延参加(iOS ブリッジ供給待ち)。この await の間も上で積んだ初期ワーカーの子タスクは
            // 並行実行される(group スコープ内の await は子を止めない)ため、Android は先に走り出す。
            // **中断が来たら供給を待たない** —— 供給(シミュレータの起動・ブリッジのビルド)は数分かかりうり、
            // 待つと Ctrl-C が効かず、2回目の Ctrl-C が後始末を飛ばして即終了する。供給は背後で最後まで
            // 走る(取り消す口が無い)が、そのデバイスにはシナリオを配らない(キュー残りは中断として記録される)
            if let late = lateWorkers {
                let joiners = await awaitUnlessInterrupted(
                    late.provider, interrupted: interruptRequested, fallback: [])
                // **1台も合流しなかった = その OS の供給が全滅 → 異常として配布を止める**(ユーザー決定)。
                // 走っているシナリオは最後まで走らせ(殺すとその結果まで失う)、残りは中止理由つきで記録する。
                // 止めるのはその OS のシナリオが待っているときだけ(待っていなければ全滅しても run の結果に関係しない)。
                // 中断で待つのをやめた場合(fallback の [])は中断として扱う
                if joiners.isEmpty, await !interruptRequested.isRequested() {
                    var pending = false
                    for (key, queue) in queues where late.platforms.contains(drainInfo(key, false).platform) {
                        if await queue.hasItems() { pending = true; break }
                    }
                    if pending {
                        lateJoinAbort.withLock { $0 = Self.lateJoinAbortReason(platforms: late.platforms) }
                        await interruptRequested.request()
                    }
                }
                // 供給が終わっても合流しなかった台(供給失敗・凍結 triage で除外など)。合流するワーカーを走らせる前に記帳する
                await Self.registerNeverJoined(planned: plannedLanes.filter { late.platforms.contains($0.platform) },
                                               joinedLanes: Set(joiners.map { ScenarioQueue.lane(of: $0) }), queues: queues, isShared: isSharedDispatch, traits: plannedTraits)
                for worker in joiners {
                    guard let queue = queues[queueKey(worker)] else { continue }
                    await joinedKeys.insert(queueKey(worker))
                    await admit(worker, queue)
                }
            }
            await closeTestingSlot()
            var failedAcrossWorkers = 0
            for await workerFailed in group { failedAcrossWorkers += workerFailed }
            return failedAcrossWorkers
        }

        // **全デバイスの仕事が終わってから** afterAll を run × クラスで1回(RunSharedSession の申告順)。
        // 走らせる先はそのクラスのシナリオが走った OS で、仕事を最後まで終えたデバイスのうち最初のもの。
        // そのデバイスの lease は runWorker が外し済みなので、走らせる間だけ取り直す(モニターを割り込ませない)
        // 遅延参加の中止は利用者の中断ではない(走り終えたレーンの afterAll は撃つ)
        let abortReason = lateJoinAbort.withLock { $0 }
        let startCancelReason = startCancelled.value
        let cancelledBeforeStart = startCancelReason != nil
        if await !stoppedByUser(), !cancelledBeforeStart {
            let lanes = finishedLanes.withLock { $0 }
            // 選んだデバイスの名前(runAfterAlls はクラスごとに target を1回ずつ申告順に呼び、結果も同じ順で返す)
            let chosenLabels = LockedValue<[String]>([])
            // 宛先はクラスの条件に合う台(DR-237)。合う台が無かった理由はクラスごとに控え、走らせなかった行に載せる
            let classRequirements = Dictionary(grouping: items) { ClassPlacementRules.className(of: $0.info.id) }
                .mapValues { DeviceRequirementGate.classLevel(of: $0.map(\.info.deviceRequirements)) }
            let afterAllGaps = LockedValue<[String: String]>([:])
            let outcomes = await ScenarioHost.runAfterAlls(
                project: project, shared: deviceSessions.shared,
                target: { [appTargets, appBundleIDs] className, platforms in
                    let choice = DeviceRequirementGate.chooseAfterAllLane(
                        requirements: classRequirements[className] ?? DeviceRequirementSet(), platforms: platforms,
                        lanes: lanes.map { (id: $0.label, platform: $0.platform, traits: $0.traits) })
                    guard case .lane(let index) = choice else {
                        if case .none(let reason?) = choice { afterAllGaps.withLock { $0[className] = reason } }
                        chosenLabels.withLock { $0.append("run") }
                        return nil
                    }
                    let lane = lanes[index]
                    chosenLabels.withLock { $0.append(lane.label) }
                    return ScenarioHost.LifecycleTarget(
                        connection: lane.connection,
                        appPath: appTargets[lane.platform]?.packagePath(physical: lane.connection.physical),
                        appName: appTargets[lane.platform]?.appName,
                        appBundleID: appBundleIDs[lane.platform])
                },
                noTargetReason: { className, _ in afterAllGaps.withLock { $0[className] } },
                settings: settings, reportDir: reportDir.path, dryRun: false,
                registerChildProcess: registerChildProcess,
                acquire: { [runLeases] connection in
                    guard let key = connection.serial ?? connection.udid else { return }
                    await runLeases.acquire(key)
                },
                release: { [runLeases] connection in
                    guard let key = connection.serial ?? connection.udid else { return }
                    await runLeases.release(key)
                })
            let labels = chosenLabels.withLock { $0 }
            for (index, outcome) in outcomes.enumerated() {
                let label = index < labels.count ? labels[index] : "run"
                continuation.yield(.workerLog(worker: label, message: ScenarioHost.describe(outcome)))
            }
        }

        heartbeat?.cancel()
        // 外し忘れた lease がないよう最終掃除(通常は runWorker / superviseWorker が既に外している)
        await runLeases.releaseAll()
        await recordingLeases.releaseAll()
        // 全ワーカー終了後に 1 回だけ index.json を書く(拡張側との契約。RecordingIndexIO 参照)
        let progressDuringClips = progressState
        await videoRecording?.finish { done, total in
            await progressDuringClips?.videoClipsProgress(done: done, total: total)
        }

        // ワーカー全滅(broadcast: そのレーンのデバイスが不在・復帰不能)でキューに残ったシナリオは失敗扱い。
        // 中断による drain は「ワーカーが使えない」ではなく事実が違うので理由を差し替える
        // (results insights が誤って「デバイス側の問題」と読まないように)
        let joined = await joinedKeys.snapshot()
        let interrupted = await stoppedByUser()
        for (key, queue) in queues {
            var drain = drainInfo(key, joined.contains(key))
            if let abortReason {
                drain.reason = abortReason
            } else if interrupted {
                drain.reason = RunRecorder.interruptedBeforeStartReason
            }
            while let item = await queue.nextLocal() {
                if cancelledBeforeStart { continue }
                // 台の条件に合う台が無いまま残った item は、読めなかった台の有無で失敗 / 対象外に確定する(DR-237)
                if abortReason == nil, !interrupted,
                   let counted = await concludeDeviceRequirementGap(item, queue: queue, platform: drain.platform,
                                                                    worker: drain.worker, perDevice: !isSharedDispatch) {
                    failed += counted
                    continue
                }
                // 対象外で戻されたまま試していない台が居なくなった item は、その事実を理由にする(DR-214)
                let reason = (abortReason == nil && !interrupted)
                    ? await queue.declaredReason(for: item).map(NotApplicableHandoff.notRunReason(declared:)) ?? drain.reason
                    : drain.reason
                continuation.yield(.flowSkipped(flowURL: item.url, reason: reason))
                recorder?.recordSkipped(unit: item.unitKey, title: item.info.title,
                                        platform: drain.platform, worker: drain.worker,
                                        reason: reason,
                                        kind: interrupted ? .interrupted : .noWorker)
                failed += 1
            }
        }

        announceNoMatchingDevice()
        await progressState?.finish()
        let unrecovered = unrecoveredDevices?() ?? []
        let used = usedDeviceKeys.withLock { $0 }
        if let notice = UnrecoveredDeviceStore.closingNotice(
            unrecovered, used: used, excludedBeforeRun: excludedBeforeRun?() ?? []) {
            continuation.yield(.workerLog(worker: "run", message: notice))
        }

        let summary = RunSummary(total: isPulled ? handedOut.value : total, failed: failed, skipped: await runSkipped.snapshot() + deviceGapSkipped.value,
                                 degradedWorkers: await degraded.snapshot(),
                                 freezeRetries: await retries.snapshot(),
                                 fmUnavailableScenarios: await fmUnavailable.snapshot(),
                                 workerAnomalies: await anomalies.snapshot(),
                                 interrupted: interrupted,
                                 abortReason: abortReason,
                                 startCancelled: startCancelReason)
        continuation.yield(.runFinished(passed: summary.passed, failed: summary.failed,
                                        skipped: summary.skipped))
        continuation.finish()
        return summary
    }

    /// 宣言されたのに合流しなかった台を、その OS のキューへ「落ちた台」として記帳する(DR-214)。
    /// shared / pulled のキューは OS ごと(キー = platform)。broadcast は1レーン1キューで回し直しが無いので記帳しない
    static func registerNeverJoined(planned: [(lane: String, platform: String)], joinedLanes: Set<String>,
                                    queues: [String: ScenarioQueue], isShared: Bool,
                                    traits: [String: DeviceTraits] = [:]) async {
        guard isShared else { return }
        for entry in planned where !joinedLanes.contains(entry.lane) {
            await queues[entry.platform]?.laneNeverJoined(entry.lane, traits: traits[entry.lane])
        }
    }

    /// 対象外で終わった item の行き先(DR-214)。判定は `NotApplicableHandoff.decide`(機械の中は `ScenarioQueue`・機械をまたぐ run は親が同じ関数)。
    /// 機械の中に回し直す先が無く、キューが親の配り手につながっていれば親へ聞く(`viaParent` = 親が他のマシンの台へ回す)。
    /// **デバイスに束ねたクラスと `@RunOnSingleMachine` は機械の外へ出さない**(`placement != nil`)
    private func resolveNotApplicable(_ item: ScenarioRunItem, worker: RunWorker, queue: ScenarioQueue,
                                      declared: String) async -> (verdict: NotApplicableHandoff.Verdict, viaParent: Bool) {
        let lane = ScenarioQueue.lane(of: worker)
        let local = await queue.noteNotApplicable(item, lane: lane, reason: declared)
        guard local != .handOn, item.info.placement == nil, let target = await queue.pullTarget() else { return (local, false) }
        let verdict = await target.source.declareNotApplicable(
            platform: target.platform, lane: lane, unit: item.unitKey,
            departedUntried: await queue.hasDepartedUntried(item), kinds: await queue.triedKinds(item))
        return (verdict, verdict == .handOn)
    }

    /// 対象外の結果を確定させずに片付ける: 記録を捨て、回し直す(`.handOn`)か実行しなかった赤にする(`.notRun`)。戻り値 = 失敗に数える本数
    private func applyNotApplicableFollowUp(
        _ followUp: (verdict: NotApplicableHandoff.Verdict, declared: String, viaParent: Bool),
        item: ScenarioRunItem, worker: RunWorker, progressLaneKey: String) async -> Int {
        recorder?.discardLast(unit: item.unitKey, worker: ScenarioRunner.recordingWorker(worker))
        switch followUp.verdict {
        case .handOn:
            let note = NotApplicableHandoff.discardedReason(declared: followUp.declared, device: worker.label, handedOn: true)
            await retries.add("\(item.info.id): \(note)")
            continuation.yield(.workerLog(worker: worker.label, message: "\(item.info.id): \(note)"))
            if followUp.viaParent {
                handedOut.withLock { $0 -= 1 }
                await progressState?.handedBack(laneKey: progressLaneKey)
            } else {
                await progressState?.laneIdled(laneKey: progressLaneKey)
            }
            return 0
        case .notRun, .skipped:
            await progressState?.scenarioFinished(laneKey: progressLaneKey, passed: false)
            return recordNotRun([item], worker: worker) { _ in NotApplicableHandoff.notRunReason(declared: followUp.declared) }
        }
    }

    /// 使用不能デバイス(画面凍結・実行中の消失)のシナリオを結果取り消し+別デバイス再キュー。
    /// requeue できたら true、上限到達で false。reason は表示・記録用の理由(例:「画面凍結」)。
    /// discardRecord=false は「シナリオ未実行のまま振り直す」プレフライト用(まだ記録が無いので
    /// discardLast を呼ばない)。post-failure は true(失敗した記録を取り消す)。
    /// **上限到達では何も書かない** —— 失敗した記録(failedSteps / errorLogs / timeline)がそのまま
    /// 一次情報として残り、呼び手が failed に数える。合成の skipped 記録で置き換えない
    /// (置き換えると最後の失敗の証拠が消え、durationMs:0 の埋め合わせだけが残る)
    private func discardAndRequeue(_ item: ScenarioRunItem, worker: RunWorker,
                                   queue: ScenarioQueue, reason: String,
                                   discardRecord: Bool = true,
                                   avoidingThisLane: Bool = false,
                                   cause: WorkerAnomalyCause?) async -> Bool {
        if let attempt = await Self.requeueDiscardingRecord(
            item, queue: queue, recorder: recorder,
            worker: ScenarioRunner.recordingWorker(worker), discardRecord: discardRecord,
            avoiding: avoidingThisLane ? worker.logicalName : nil) {
            await retries.add("\(item.info.id): \(reason) (requeued from \(worker.label), \(attempt)/\(MAX_FREEZE_RETRIES))")
            await anomalies.add(WorkerAnomalyRecord(
                kind: "requeued", worker: Self.workerID(worker), label: worker.label,
                scenarioID: item.info.id,
                reason: "\(reason) (attempt \(attempt)/\(MAX_FREEZE_RETRIES))", cause: cause))
            continuation.yield(.flowRequeued(worker: worker.label, flowURL: item.url,
                                             reason: reason, attempt: attempt,
                                             limit: MAX_FREEZE_RETRIES))
            return true
        }
        let message = "\(reason); retry limit reached (\(MAX_FREEZE_RETRIES)), the failed result stands"
        await retries.add("\(item.info.id): \(message) (\(worker.label))")
        await anomalies.add(WorkerAnomalyRecord(
            kind: "retryLimit", worker: Self.workerID(worker), label: worker.label,
            scenarioID: item.info.id, reason: message, cause: cause))
        // flowSkipped は出さない —— runOne が flowStarted〜flowFinished(passed:false) を既に流して
        // おり、重ねると NDJSON 側(ApiRunCommand)が同じシナリオの scenarioStarted/Finished を
        // もう1組合成する
        continuation.yield(.workerLog(worker: worker.label,
                                      message: "⛔ \(item.info.id): \(message)"))
        return false
    }

    /// requeue の可否を先に決め、**成立したときだけ**直前の記録を消す(戻り値は何回目の再実行か。
    /// 上限なら nil で記録は触らない)。順序を逆にすると、上限到達の回で失敗記録を消した後に
    /// 戻せなくなる。worker は記録の `worker` と同じ文字列(`ScenarioRunner.recordingWorker`)——
    /// broadcast では同じ ID を別のデバイスが同時に書いているので名指しで消す
    static func requeueDiscardingRecord(_ item: ScenarioRunItem, queue: ScenarioQueue,
                                        recorder: RunRecorder?, worker: String?,
                                        discardRecord: Bool, avoiding lane: String? = nil) async -> Int? {
        guard let attempt = await queue.requeue(item, avoiding: lane) else { return nil }
        if discardRecord {
            recorder?.discardLast(unit: item.unitKey, worker: worker)
        }
        return attempt
    }

    /// 表示条件がアプリへ届かなかった赤(`display-not-applied`)を、回復の要求と振り直しの対象にするか。
    /// iOS Simulator だけ(実機は SpringBoard を起こし直せない = 失敗のまま。Android はこの検出を持たない)
    static func requeuesForDisplayNotApplied(platform: String, physical: Bool, failedStepKinds: [String?]) -> Bool {
        platform == "ios" && !physical && failedStepKinds.contains(StepFailureKind.displayNotApplied.rawValue)
    }

    /// retired ワーカーを reviveWorker で復帰させ、同じ queue の消化を継続する。
    /// runWorker が .completed を返すまで(または復帰を諦めるまで)ループする。
    private func superviseWorker(_ worker: RunWorker, queue: ScenarioQueue) async -> Int {
        var current = worker
        var totalFailed = 0
        var revives = 0
        while true {
            switch await runWorker(current, queue: queue, revived: revives > 0) {
            case .completed(let f):
                let lane = FinishedLane(label: current.label, platform: current.platform,
                                        connection: current.connection, leaseKey: Self.leaseKey(current),
                                        traits: current.effectiveTraits)
                finishedLanes.withLock { $0.append(lane) }
                return totalFailed + f
            case .retired(let f, let retired):
                totalFailed += f
                // **離脱したデバイスの run-lease は復帰を諦めるまで外さない**(runWorker は離脱時に外さない)。
                // 復帰(ブリッジの作り直しで数十秒)の間に外すと、モニターの watchdog と配信が
                // そのデバイスへ割り込む —— 「供給フェーズの穴」(SupplyLeaseHolder)と同じ型
                let retiredKey = Self.leaseKey(retired)
                // ウェッジしたブリッジプロセスの停止は復帰の有無に関係なく必ず行う(プロパティ宣言の
                // コメント参照)。復帰する場合も、供給前に旧プロセスを止めておく方が安全
                await cleanupRetiredWorker?(retired)
                // 描画の状態で離脱したデバイスは、revive の前に回復を1回撃つ(テスト中ではない)。revive できない離脱
                // (キューが空・復帰未注入・上限)では撃たない = 起動し直しの数十秒を払うだけで、次の run の前の点検が同じ台帳で拾う
                // **中断中は撃たない・復帰させない**(キューは中断後も残るので `hasItems` だけでは門にならない。
                // 回復の待ち(Emulator の起動待ち最大120秒)と revive の作り直しで、中断の応答が数十秒遅れた)
                if let state = renderingPending.withLock({ $0.removeValue(forKey: Self.leaseKey(retired) ?? retired.label) }),
                   let recoverRendering, revives < MAX_WORKER_REVIVES, reviveWorker != nil, await queue.hasItems(lane: ScenarioQueue.lane(of: retired)),
                   await !stoppedByUser() {
                    let log: @Sendable (String) -> Void = { [continuation, label = retired.label] message in
                        continuation.yield(.workerLog(worker: label, message: message))
                    }
                    switch await recoverRendering(retired, state, log) {
                    case .recovered(let kind):
                        await anomalies.add(WorkerAnomalyRecord(
                            kind: "recovered", worker: Self.workerID(retired), label: retired.label,
                            reason: "recovered a \(state.rawValue) screen", cause: .rendering, recovery: kind))
                    case .notRecovered(let kind):
                        await anomalies.add(WorkerAnomalyRecord(
                            kind: "recovered", worker: Self.workerID(retired), label: retired.label,
                            reason: "restarted after a \(state.rawValue) screen; the screen did not come back",
                            cause: .rendering, recovery: kind))
                        await anomalies.add(WorkerAnomalyRecord.rebootAdvice(retired, state: state))
                    case .advised:
                        await anomalies.add(WorkerAnomalyRecord.rebootAdvice(retired, state: state))
                    case .deviceGone:
                        // 再起動は完了していない・マシンの再起動で戻る事象とも言えない = 回復も案内も記録せず、消えた事実だけを置く
                        await anomalies.add(WorkerAnomalyRecord(
                            kind: "degraded", worker: Self.workerID(retired), label: retired.label,
                            reason: "the device disappeared while it was being restarted after a \(state.rawValue) screen",
                            cause: .deviceGone))
                    case .notAttempted:
                        break
                    }
                }
                // queue が空/復帰未注入/復帰回数上限 のいずれかならこれ以上粘っても無駄なので諦める
                guard revives < MAX_WORKER_REVIVES, await queue.hasItems(lane: ScenarioQueue.lane(of: retired)), await !stoppedByUser(),
                      let revive = reviveWorker else {
                    if let retiredKey { await runLeases.release(retiredKey) }
                    await closeTestingSlot()
                    return totalFailed
                }
                continuation.yield(.workerLog(worker: retired.label,
                    message: "🔧 Trying to revive the worker (\(revives + 1)/\(MAX_WORKER_REVIVES); "
                        + "recreating the bridge can take tens of seconds)..."))
                guard let newWorker = await revive(retired) else {
                    continuation.yield(.workerLog(worker: retired.label,
                        message: "⛔ Could not revive the worker"))
                    if let retiredKey { await runLeases.release(retiredKey) }
                    await closeTestingSlot()
                    return totalFailed
                }
                // 復帰先が別のキー(別の serial で上がり直した等)なら旧キーはもう誰も使わない。
                // 同じキーなら次の runWorker がそのまま引き継ぐ
                if let retiredKey, retiredKey != Self.leaseKey(newWorker) {
                    await runLeases.release(retiredKey)
                }
                revives += 1
                continuation.yield(.workerLog(worker: newWorker.label,
                    message: "✅ Worker revived — resuming the run"))
                continuation.yield(.workerReady(worker: newWorker.label))
                await anomalies.add(WorkerAnomalyRecord(
                    kind: "recovered", worker: Self.workerID(newWorker), label: newWorker.label,
                    reason: "worker revived after \(retired.label) dropped out",
                    recovery: .workerRevive))
                // 起こし直したデバイスは admit を通らないので、ここで記録し直す(別のモードで戻ったら後の値が残る)
                if let record = newWorker.modeRecord { recorder?.recordWorkerMode(record) }
                // 台の性質は論理デバイスの性質(復帰で観測し直さない)
                current = newWorker.deviceTraits == nil ? newWorker.with(deviceTraits: retired.deviceTraits) : newWorker
            }
        }
    }

    /// 使用不能になったレーンの離脱: 直前のシナリオの結果を捨てて振り直し(上限あり)、レーンを離れる。
    /// run-lease はここでは外さない(superviseWorker が復帰の成否で決める)
    /// `invalidatesPassedRecord`: 直前のシナリオは**成功として記録済み**で、後から信用できないと分かった(境目の表示の確認)。
    /// 振り直しの上限で取り消せない回は、記録を失敗へ書き換えて数と揃える(成功の記録のまま failed だけ増やすと、個別 JSON・
    /// `ft_run_status` の失敗一覧・`--failed` が run の集計と食い違う)。読み手への終了イベントは確認まで保留して失敗として
    /// 流している(runWorker の heldFinish)。理由はそのレーンのログに 1 行出す
    /// 確認の後に前面へ戻すアプリ = **そのシナリオが使ったアプリ**(子と同じ `ScenarioAppResolution`)。
    /// 決まらなければ nil(戻さない)
    static func restoreAppID(fromProfile: String?, scenarioID: String) -> String? {
        if case .resolved(let bundleID) = ScenarioAppResolution.resolve(
            fromProfile: fromProfile, scenarioID: scenarioID) { return bundleID }
        return nil
    }

    /// 終了イベントの合否を失敗へ直す(対象外の宣言はそのまま = 画面を見ていない)。他の欄は変えない
    static func failedFinish(_ event: RunEvent, discardReason: String?) -> RunEvent {
        guard case .flowFinished(let worker, let url, let passed, let report, let fm, let crash, let notApplicable, _) = event,
              notApplicable == nil else { return event }
        return .flowFinished(worker: worker, flowURL: url, passed: false, reportURL: report, fm: fm,
                             appCrash: crash, notApplicableReason: nil,
                             resultDiscardedReason: passed ? discardReason : nil)
    }

    /// 実行しなかった赤をドレインと同じ形で記録する。**サーキットブレーカには数えない**(1本の失敗で健全なデバイスを離脱させない)。
    /// 戻り値 = 失敗に数える本数
    private func recordNotRun(_ items: [ScenarioRunItem], worker: RunWorker,
                              reason: (ScenarioRunItem) -> String) -> Int {
        for item in items {
            let text = reason(item)
            continuation.yield(.flowSkipped(flowURL: item.url, reason: text))
            recorder?.recordSkipped(unit: item.unitKey, title: item.info.title, platform: worker.platform,
                                    worker: ScenarioRunner.recordingWorker(worker), reason: text)
        }
        return items.count
    }

    /// 失敗が確定した @RunInOrder のテストの後、同じクラスの残りを実行しない(振り直す分では呼ばない)。戻り値 = 失敗に数える本数
    private func abandonInOrder(after item: ScenarioRunItem, worker: RunWorker, queue: ScenarioQueue) async -> Int {
        let rest = await queue.abandonInOrderClass(after: item, lane: ScenarioQueue.lane(of: worker))
        return recordNotRun(rest, worker: worker) { _ in ClassPlacementRules.notRunReason(failedID: item.unitKey.description) }
    }

    /// 失敗が確定した1本ぶん(1)+@RunInOrder で実行しなかった残り
    private func failureCount(_ item: ScenarioRunItem, worker: RunWorker, queue: ScenarioQueue) async -> Int {
        let rest = await abandonInOrder(after: item, worker: worker, queue: queue)
        return 1 + rest
    }

    private func retireUnusable(_ item: ScenarioRunItem, worker: RunWorker, queue: ScenarioQueue,
                                reason: String, cause: WorkerAnomalyCause?, failed: Int,
                                progressLaneKey: String, leaseKey: String?,
                                invalidatesPassedRecord: Bool = false,
                                keepsFailedResult: Bool = false) async -> WorkerExit {
        var failed = failed
        let requeued = keepsFailedResult
            ? false
            : await discardAndRequeue(item, worker: worker, queue: queue, reason: reason, cause: cause)
        if keepsFailedResult {
            continuation.yield(.workerLog(worker: worker.label,
                message: "\(item.info.id): the failed result stands (not requeued); the lane is dropped because of \(reason)"))
        }
        if requeued {
            await progressState?.laneIdled(laneKey: progressLaneKey)
        } else {
            if invalidatesPassedRecord {
                let message = "the result is not trusted: \(reason) was found right after this scenario passed, and the"
                    + " retry limit was reached, so it is recorded as failed"
                recorder?.markLastFailed(unit: item.unitKey,
                                         worker: ScenarioRunner.recordingWorker(worker), reason: message)
                continuation.yield(.workerLog(worker: worker.label, message: "❌ \(item.info.id): \(message)"))
            }
            await progressState?.scenarioFinished(laneKey: progressLaneKey, passed: false)
            failed += await failureCount(item, worker: worker, queue: queue)
        }
        if cause == .frozen { await progressState?.deviceStateObserved(deviceKey: progressLaneKey, state: .frozen) }
        await reportWorkerFailed(worker, "dropped out because of \(reason)", cause: cause)
        // このレーンはもう走らない(復帰できれば superviseWorker が新しい runWorker で laneJoined を呼び直す)
        await progressState?.laneLeft(key: progressLaneKey)
        renderingBook.withLock { $0.leave(laneKey: progressLaneKey) }
        await stopRecording(worker, leaseKey: leaseKey)
        return .retired(failed: failed, worker: worker)
    }

    /// 描画の状態の報告から1つ選ぶ。両方出ていれば blank(白紙は文字消えを含む重い側)
    static func reportedScreenState(_ states: Set<DeviceScreenState>) -> DeviceScreenState? {
        states.contains(.blank) ? .blank : states.first
    }

    private func runWorker(_ worker: RunWorker, queue: ScenarioQueue, revived: Bool) async -> WorkerExit {
        // 期限付き(ウェッジしたブリッジで 120s×N 待たないため。withDeadline 参照)。
        guard await withDeadline(seconds: 10, { try await worker.driver.status() }) != nil else {
            await reportWorkerFailed(worker, "dropped out — cannot connect (no response to status)", cause: .noResponse)
            // 接続不能もデバイス使用不能の一種として復帰トライの対象にする(監視側の再起動待ち等)。
            // lease の扱いは superviseWorker が決める(離脱の lease は復帰を諦めるまで保つ)
            return .retired(failed: 0, worker: worker)
        }
        // コールドブート直後のシミュレータは最初の AX 問い合わせが極端に遅い
        // (kAXErrorIPCTimeout でランナーが落ちる)ため、snapshot で温める(リトライ1回)
        if await withDeadline(seconds: 15, { try await worker.driver.snapshot() }) == nil {
            _ = await withDeadline(seconds: 15, { try await worker.driver.snapshot() })
        }
        continuation.yield(.workerReady(worker: worker.label))

        let leaseKey = Self.leaseKey(worker)
        if let leaseKey {
            await runLeases.acquire(leaseKey)
        }
        // run 進捗のレーン鍵。**run-lease と同じ鍵体系を使う**が、lease が持てない接続
        // (--port 等 udid/serial の無い経路。この orchestrator では progressState 自体が
        // 未注入なので実質関係ない)でも記帳自体は続けられるよう label へ縮退する
        let progressLaneKey = leaseKey ?? worker.label
        renderingBook.withLock { $0.join(laneKey: progressLaneKey, platform: worker.platform, label: worker.label) }
        if let leaseKey { usedDeviceKeys.withLock { _ = $0.insert(leaseKey) } }
        // compile-ocr の待ちがあるなら、レーンを見せる最初の記帳から段階を "compiling" にする(running を一瞬挟まない)
        let waitsForOCRCompile = ScenarioHost.isOCRModelCompileWaitPending
        if waitsForOCRCompile {
            await progressState?.ocrCompileWaitBegan()
        }
        // **名前はモニターのタイルと同じ logicalName**(実行プロファイルの devices[].name)——
        // label はポート込み("…-01(ios:8130)")なので、同じデバイスがボードとタイルで別名に見える
        await progressState?.laneJoined(key: progressLaneKey,
                                        name: worker.logicalName ?? worker.label,
                                        platform: worker.platform)

        // 録画プロセスの起動に成功したときだけ RecordingLease を書く(record:false・adb/udid 不明・
        // プロセス spawn 失敗はいずれも false を返し、lease は書かれない)
        if await videoRecording?.start(worker) == true {
            await testingSlots.noteRecordingStarted()
            if let leaseKey {
                await recordingLeases.acquire(leaseKey)
            }
        }
        // **シナリオの印(run ボードの経過・残りの起点)より前で待つ**。ScenarioHost.run の中で待つと、
        // 何も動いていない間にレーンの経過と残りの秒読みが進む(シナリオの所要の実績は待ちの後から計っている)
        if waitsForOCRCompile {
            await ScenarioHost.awaitOCRModelCompileBeforeScenarios { message in
                continuation.yield(.workerLog(worker: worker.label, message: message))
            }
            await progressState?.ocrCompileWaitEnded()
        }

        var failed = 0
        // 連続失敗は前の run から引き継ぐ(LaneFailureStreakStore)。鍵が無い(論理名なし)・注入が無いときは 0 から
        let streakKey = Self.workerID(worker)
        // **起こし直したレーンは台帳を消して 0 から数え直す**: 離脱は「他のレーンが通る間にこのレーンが閾値回落ちた」証拠で、
        // ブリッジを作り直した後の状態には当たらない。持ち越すと閾値ちょうどで始まり、決定的な赤1本でまた離脱して復帰回数を焼く
        // (直っていなければ閾値回の赤で再び外れる。run をまたぐ持ち越しは台帳のまま)
        if revived, let s = laneStreakKey(streakKey) { LaneFailureStreakStore.clear(stateDir: s.dir, key: s.key) }
        var breaker = WorkerCircuitBreaker(
            threshold: WORKER_FAILURE_CIRCUIT_THRESHOLD,
            // 消去(try?)が黙って失敗しても読まない = 復帰したレーンは必ず 0 から
            carriedFailures: revived ? 0 : laneStreakKey(streakKey).map {
                LaneFailureStreakStore.load(stateDir: $0.dir, key: $0.key, scope: project.name) } ?? 0)
        // 実行前のブリッジ疎通確認(プレフライト)は不採用(ユーザー決定)。
        // 「取ってから判定」版は一過性の AX スパイクで9台一斉離脱、「取る前に2sで即断」版も
        // 負荷時の誤判定で品質が安定しなかった。ウェッジは失敗後の事後チェック
        // (bridgeUnreachable/deviceUnreachable/deviceFrozen → 振り直し)だけで拾う。
        // 中断要求後は新しいシナリオを配らない(既にキューから抜けた1件は最後まで走らせる ——
        // ここで打ち切ると in-flight の子プロセスと記録の整合が崩れる。子を止めるのは
        // registerChildProcess 経由の SIGTERM で、呼び出し側の責務)
        while await !interruptRequested.isRequested(), let item = await queue.next(lane: ScenarioQueue.lane(of: worker), shouldStop: { [interruptRequested] in
            await interruptRequested.isRequested() }) {
            // @RunInOrder のクラスが同じレーンで先に失敗していたら実行せずに赤(配り手から受け取る経路)
            if let reason = await queue.inOrderSkipReason(for: item, lane: ScenarioQueue.lane(of: worker)) {
                failed += recordNotRun([item], worker: worker) { _ in reason }
                continue
            }
            let positionNotice = await queue.positionNotice(for: item)
            // 録画の区間・進捗の開始より前に置く(消すのに掛かった時間をシナリオに数えない)。
            // 何をしたかは**そのシナリオのログ**に残す(結果のイベントログに載る = 権限を拒否で閉じた等が残る)
            let residualAlertNotice = await clearResidualSystemAlert?(worker)
            // **録画が撮れていることを確かめてから始める**(止まっていれば撮り直して開始を確かめる・駄目なら静止画方式へ)。
            // 静止画方式(物理 iPhone・動画を起動/撮り直しできなかったデバイス)は子が操作の直後に撮る置き場を返す。動画なら nil
            let stillFramesDir = await videoRecording?.prepareScenario(workerLabel: worker.label)
            // 動画のシナリオ毎クリップ切り出し用の壁時計区間通知(録画無効時は no-op)。
            // ワーカーの録画プロセス自体は起動しっぱなしで、ここでは区間だけ記録する
            await videoRecording?.scenarioStarted(
                workerLabel: worker.label, unit: item.unitKey, at: Date())
            await progressState?.scenarioStarted(laneKey: progressLaneKey, scenario: item.info.id,
                                                 variant: item.variant, at: Date())
            let slowestStep = SlowestStepSnapshot()
            let observedScreenStates = LockedValue<Set<DeviceScreenState>>([])
            let failedStepKinds = LockedValue<[String?]>([])
            // **終了イベントは境目の表示の確認まで保留する**(確認が凍結を確定したら合否を失敗へ直して流す = Test Explorer などの
            // 読み手が「合格」を見たまま残らない。NDJSON は scenarioFinished を取り消す口を持たない)。確認を注入していなければ保留しない。
            // 保留の分だけ読み手の受け取り時刻が遅れるので、送った時刻は flowStartedAt / flowEndedAt で別に運ぶ(所要の集計が確認・回復の時間を含まない)
            let holdsFinish = checkLaneDisplay != nil || detachesRendering.withLock { $0 }
            let heldFinish = LockedValue<(event: RunEvent, at: Date)?>(nil)
            let outcome = await ScenarioRunner.runOne(
                project: project, item: item, worker: worker,
                deviceSession: deviceSessions.session(for: BroadcastPlan.laneKey(of: worker)),
                settings: settings, reportDir: reportDir,
                debug: debug,
                recorder: recorder, installHandler: installHandler,
                appName: appTargets[worker.platform]?.appName,
                appBundleID: appBundleIDs[worker.platform],
                appPath: appTargets[worker.platform]?
                    .packagePath(physical: worker.connection.physical),
                hostNotices: (residualAlertNotice.map { [$0] } ?? []) + (positionNotice.map { [$0] } ?? []),
                registerChildProcess: registerChildProcess,
                humanOperationsStateDir: humanOperationsStateDir,
                onActions: { [weak self] actions in
                    guard let self else { return }
                    Task { await self.progressState?.addActions(actions) }
                },
                onEventLogStarted: { [weak self] url in
                    guard let self else { return }
                    let laneKey = progressLaneKey
                    Task { await self.progressState?.setLaneEventLog(laneKey: laneKey, path: url.path) }
                },
                stillFramesDir: stillFramesDir,
                onEvent: { [continuation, fmCounter = self.fmUnavailable] event in
                    // **FM 全滅のまま走ったシナリオを数える**(合否は変えない。summary の
                    // fmUnavailableScenarios。ここで数えるのは、実行結果に FM の可否が
                    // 現れないため —— 失敗は各呼び出し箇所が握って素通りさせる契約)
                    if case .flowFinished(_, _, _, _, let fm, _, _, _) = event,
                       RunSummary.fmUnavailable(fm) {
                        Task { await fmCounter.increment() }
                    }
                    if case .step(_, _, let result) = event, let ms = result.timing?.snapshotMs {
                        slowestStep.note(ms)
                    }
                    if case .step(_, _, let result) = event, !result.synthetic, case .failed = result.status {
                        failedStepKinds.withLock { $0.append(result.failureKind) }
                    }
                    if case .step(_, _, let result) = event {
                        let states = Set((result.notes ?? []).compactMap(RunDeviceState.init(note:)))
                        let screenStates = states.compactMap(\.screenState)
                        if !screenStates.isEmpty { observedScreenStates.withLock { $0.formUnion(screenStates) } }
                        if !states.isEmpty {
                            let laneKey = progressLaneKey
                            Task {
                                for state in states { await self.progressState?.deviceStateObserved(deviceKey: laneKey, state: state) }
                            }
                        }
                    }
                    if case .flowStarted(let worker, let flowURL, _, _) = event {
                        continuation.yield(.flowStartedAt(worker: worker, flowURL: flowURL, at: Date()))
                    }
                    if case .flowFinished(let worker, let flowURL, _, _, _, _, let declaredNotApplicable, _) = event {
                        let at = Date()
                        // 対象外の終了も保留する: 回し直す・実行しなかった赤にするかは終わってから決まる(DR-214)
                        if holdsFinish || declaredNotApplicable != nil {
                            heldFinish.withLock { $0 = (event, at) }
                            return
                        }
                        continuation.yield(.flowEndedAt(worker: worker, flowURL: flowURL, at: at))
                    }
                    continuation.yield(event)
                })
            // 表示条件がアプリへ届かなかった iOS Simulator は、次のシナリオの前に SpringBoard を起こし直す(`clearResidualSystemAlert` の口が取り出す)。
            // 実機は回復しない(失敗のまま)。失敗したシナリオは振り直さない
            if Self.requeuesForDisplayNotApplied(platform: worker.platform, physical: worker.connection.physical,
                                                 failedStepKinds: failedStepKinds.withLock { $0 }) {
                DisplayRecoveryRequests.shared.request(label: worker.label)
            }
            // 録画の区間の終わりは**確認の前**の時刻(確認・回復の時間をシナリオの区間に入れない)。合否は確認の後に決める ——
            // 凍結が確定した成功は録画にとっても失敗(recordFailuresOnly で問題の区間を残すため)
            let scenarioEndedAt = Date()
            // **表示が止まっていないかを境目で確かめる**(DisplayFreezeWatch)。確定したら合否を問わず .frozen と同じ扱い ——
            // 直前のシナリオの画像判定(分類器・findImage・可視性検証)は止まった絵で下されているので、結果を捨てて振り直す。
            // .frozen(子の明示の信号)の後・中断中は確かめない(どちらも次のシナリオを配らない)。**対象外(notApplicable)の後も
            // 確かめない** —— 画面を見ていないので捨てる結果が無く、上限で書き換える成功の記録も無い(次の境目が確かめる)
            var displayFreeze: (detail: String, recovery: WorkerRecoveryKind?)?
            if outcome != .frozen, outcome != .notApplicable, let checkLaneDisplay,
               await !stoppedByUser(),
               case .frozen(let detail, let recovery) = await checkLaneDisplay(
                   worker, Self.restoreAppID(fromProfile: appBundleIDs[worker.platform],
                                             scenarioID: item.info.id), { [continuation] message in
                       continuation.yield(.workerLog(worker: worker.label, message: message))
                   }) {
                displayFreeze = (detail, recovery)
            }
            // **描画の状態(白紙・文字消え)を報告したレーンの切り離し**。凍結が確定した回は凍結が先(同じレーンを二重に離脱させない)。
            // 緑で終わった回も、画素で確かめられていない検証を含むので凍結と同じく結果を捨てる(invalidatesPassedRecord)
            // **緑と素の赤だけ**(一過性の故障・ブリッジ不達は下の仕分けと事後プローブが先)・中断中は撃たない・ブリッジが答えないデバイスは消失の経路へ回す
            var renderingDetach: DeviceScreenState?
            if displayFreeze == nil, outcome == .passed || outcome == .failed, detachesRendering.withLock({ $0 }),
               let state = Self.reportedScreenState(observedScreenStates.withLock { $0 }),
               await !stoppedByUser(),
               await withDeadline(seconds: 10, { try await worker.driver.status() }) != nil {
                switch renderingBook.withLock({ $0.decide(laneKey: progressLaneKey, platform: worker.platform,
                                                           scenarioID: item.info.id, state: state) }) {
                case .detach:
                    renderingDetach = state
                case .keepNoOtherLane:
                    let message = "the screen was reported as \(state.rawValue), but no other \(worker.platform) lane is running —"
                        + " keeping the lane (a lane is detached only when another one can take its scenarios)"
                    continuation.yield(.workerLog(worker: worker.label, message: "⚠️ \(message)"))
                    await anomalies.add(WorkerAnomalyRecord(
                        kind: "renderingHeld", worker: Self.workerID(worker), label: worker.label,
                        scenarioID: item.info.id, reason: message, cause: .rendering))
                case .keepReportedByOtherLane(let lane):
                    let message = "the screen was reported as \(state.rawValue) on \(lane) as well for this scenario —"
                        + " keeping the lane and the result"
                    continuation.yield(.workerLog(worker: worker.label, message: "⚠️ \(message)"))
                    await anomalies.add(WorkerAnomalyRecord(
                        kind: "renderingHeld", worker: Self.workerID(worker), label: worker.label,
                        scenarioID: item.info.id, reason: message, cause: .rendering))
                }
            }
            // 対象外の行き先(DR-214)。凍結・描画崩壊が確定した回は結果を捨てる側が先(対象外では起きない形だが順序を固定する)
            var notApplicableFollowUp: (verdict: NotApplicableHandoff.Verdict, declared: String, viaParent: Bool)?
            if outcome == .notApplicable, displayFreeze == nil, renderingDetach == nil,
               let held = heldFinish.withLock({ $0 }),
               case .flowFinished(_, _, _, _, _, _, let declared?, _) = held.event {
                let resolved = await resolveNotApplicable(item, worker: worker, queue: queue, declared: declared)
                if let note = declaredMatchNote(item: item, worker: worker, declared: declared) {
                    continuation.yield(.workerLog(worker: worker.label, message: note))
                }
                if resolved.verdict != .skipped {
                    notApplicableFollowUp = (resolved.verdict, declared, resolved.viaParent)
                }
            }
            // 保留した終了イベントを流す(凍結が確定したら失敗として。振り直しの requeued はこの後に続く = 凍結の失敗と同じ並び)
            if let held = heldFinish.withLock({ $0 }),
               case .flowFinished(let heldWorker, let heldURL, let heldPassed, let heldReport, _, _, _, _) = held.event {
                continuation.yield(.flowEndedAt(worker: heldWorker, flowURL: heldURL, at: held.at))
                let discardReason = displayFreeze.map { "a frozen display (\($0.detail))" }
                    ?? renderingDetach.map { "a \($0.rawValue) screen" }
                if let discardReason {
                    continuation.yield(Self.failedFinish(held.event, discardReason: discardReason))
                    // レポートは子が緑のまま書き終えている。親だけが捨てたことを知っている
                    if heldPassed, let heldReport { ScenarioReportNotice.addDiscarded(reason: discardReason, to: heldReport) }
                } else if let followUp = notApplicableFollowUp,
                          case .flowFinished(let w, let u, _, let report, let fm, let crash, _, _) = held.event {
                    continuation.yield(.flowFinished(
                        worker: w, flowURL: u, passed: false, reportURL: report, fm: fm, appCrash: crash,
                        notApplicableReason: nil,
                        resultDiscardedReason: NotApplicableHandoff.discardedReason(
                            declared: followUp.declared, device: worker.label, handedOn: followUp.verdict == .handOn)))
                } else {
                    continuation.yield(held.event)
                }
            }
            await videoRecording?.scenarioFinished(
                workerLabel: worker.label, at: scenarioEndedAt,
                passed: displayFreeze == nil && renderingDetach == nil && (outcome == .passed || outcome == .notApplicable))
            if let displayFreeze {
                if let recovery = displayFreeze.recovery {
                    await anomalies.add(WorkerAnomalyRecord(
                        kind: "recovered", worker: Self.workerID(worker), label: worker.label,
                        scenarioID: item.info.id, reason: "recovered a frozen display: \(displayFreeze.detail)",
                        cause: .frozen, recovery: recovery))
                }
                return await retireUnusable(item, worker: worker, queue: queue,
                                            reason: "a frozen display (\(displayFreeze.detail))", cause: .frozen,
                                            failed: failed, progressLaneKey: progressLaneKey, leaseKey: leaseKey,
                                            invalidatesPassedRecord: outcome == .passed)
            }
            if let state = renderingDetach {
                renderingPending.withLock { $0[progressLaneKey] = state }
                return await retireUnusable(item, worker: worker, queue: queue,
                                            reason: "a \(state.rawValue) screen", cause: .rendering,
                                            failed: failed, progressLaneKey: progressLaneKey, leaseKey: leaseKey,
                                            invalidatesPassedRecord: outcome == .passed)
            }
            if outcome == .passed || outcome == .notApplicable {
                if outcome == .notApplicable, notApplicableFollowUp == nil { await runSkipped.increment() }
                breaker.recordPass()
                if let s = laneStreakKey(streakKey) { LaneFailureStreakStore.clear(stateDir: s.dir, key: s.key) }
                if outcome == .passed { _ = await witnessOutcome(unit: item.unitKey, worker: streakKey, passed: true) }
                await runPasses.increment()
                if let followUp = notApplicableFollowUp {
                    failed += await applyNotApplicableFollowUp(
                        followUp, item: item, worker: worker, progressLaneKey: progressLaneKey)
                } else {
                    await progressState?.scenarioFinished(laneKey: progressLaneKey, passed: true)
                }
                // **レーンが空いている今だけ測り直す**(次の 1 件をまだ取っていない)。
                // 失敗の経路は除く —— 離脱すれば revive が供給を通り、そこで同じ 1 問が測る。
                // 中断中・残りが無いときは撃たない(起動し直しは数十秒かかり、次の run の再利用が測る)
                if let recheckRunner, await !interruptRequested.isRequested(), await queue.hasItems(lane: ScenarioQueue.lane(of: worker)) {
                    let verdict = await recheckRunner(worker, slowestStep.value) { [continuation] message in
                        continuation.yield(.workerLog(worker: worker.label, message: message))
                    }
                    switch verdict {
                    case .restarted:
                        await anomalies.add(WorkerAnomalyRecord(
                            kind: "recovered", worker: Self.workerID(worker), label: worker.label,
                            reason: "restarted the xcuitest bridge after a mid-run degradation",
                            recovery: .runnerRestart))
                    case .unchanged:
                        break
                    case .unusable(let reason):
                        // 直前のシナリオは緑で記録済み(振り直さない)。このレーンだけ離脱する
                        await reportWorkerFailed(worker, "dropped out because of \(reason)", cause: .noResponse)
                        await progressState?.laneLeft(key: progressLaneKey)
                        renderingBook.withLock { $0.leave(laneKey: progressLaneKey) }
                        await stopRecording(worker, leaseKey: leaseKey)
                        return .retired(failed: failed, worker: worker)
                    }
                }
                continue
            }
            // **デバイス基盤の一過性エラー**(kAXErrorAPIDisabled 等。全 OS)は結果を捨てて振り直す。
            // **ワーカーは離脱させない** —— 個体は健全で、ブリッジを作り直しても同じ確率で踏む
            // (実測でも再実行で必ず消えた)。連続失敗の数にも入れない = サーキットブレーカを
            // 環境ノイズで作動させない。
            // **ドライバ不達(driverUnreachable)はここでは判定しない** —— デバイスが消えた/凍った形も
            // 同じ failureKind で来る(実測: エミュレータの qemu を kill すると driver-unreachable →
            // 消失)ので、下の事後プローブ(消失・凍結)を先に通してからでないと、**死んだレーンを
            // 離脱させずに振り直し続ける**ことになる
            // **表示条件がアプリへ届かなかった iOS Simulator**(外観が届かない件 = docs/verification/resolved.md)は結果を捨てて1回だけ振り直す。端末の設定は読み返しで合い、
            // アプリは別の値を報告した = 観測で確定した端末の不調で、テスト対象の情報が無い。回復(SpringBoard の起こし直し)は
            // このレーンの次のシナリオの前に走る(上の DisplayRecoveryRequests)ので、レーンは離脱させない。
            // 同じレーンへ戻っても回復の後に走る。上限の回は失敗を残す(回復できない台で振り直し続けない)
            if outcome == .failed, Self.requeuesForDisplayNotApplied(
                platform: worker.platform, physical: worker.connection.physical,
                failedStepKinds: failedStepKinds.withLock { $0 }) {
                let requeued = await discardAndRequeue(item, worker: worker, queue: queue,
                                                       reason: "display settings that did not reach the app",
                                                       cause: .displayNotApplied)
                if requeued {
                    await progressState?.laneIdled(laneKey: progressLaneKey)
                } else {
                    await progressState?.scenarioFinished(laneKey: progressLaneKey, passed: false)
                    failed += await failureCount(item, worker: worker, queue: queue)
                }
                continue
            }
            if outcome == .environmentFault {
                let requeued = await discardAndRequeue(item, worker: worker, queue: queue,
                                                       reason: "a transient accessibility fault",
                                                       cause: .accessibilityFault)
                if requeued {
                    await progressState?.laneIdled(laneKey: progressLaneKey)
                } else {
                    await progressState?.scenarioFinished(laneKey: progressLaneKey, passed: false)
                }
                if !requeued { failed += await failureCount(item, worker: worker, queue: queue) }
                continue
            }
            // デバイスが使用不能なら結果取り消し+別デバイス再実行+ワーカー離脱。
            // .frozen(スクショ由来の明示シグナル)は即。.failed は事後プローブで確認:
            // まず消失(adb offline/未検出。安価な adb devices 1回)、次に画面凍結(screencap プローブ)。
            // iOS はブリッジ /status の生存確認(ブリッジのウェッジ=シナリオ途中から全ステップが
            // 接続エラーになる実害があり、Android のプローブでは拾えない)。
            var unusableReason: String? = outcome == .frozen ? "a frozen screen" : nil
            // unusableReason と**同時に**決める(型から。文言の後解析はしない)
            var unusableCause: WorkerAnomalyCause? = outcome == .frozen ? .frozen : nil
            if unusableReason == nil, outcome == .failed || outcome == .driverUnreachable || outcome == .appCrashed
                || outcome == .appInBackground,
               worker.platform == "android",
               let serial = worker.connection.serial {
                if await deviceUnreachable(serial) {
                    // 消失判定(adb devices)は実機でも有効。USB 抜け・WiFi 断の検知に使える。
                    // **エミュレータなら自分のログを名指しする** —— qemu 自身が FATAL 終了した
                    // ときの理由(Vulkan 等)はこのログの末尾にしか出ず、案内が無いと
                    // DiagnosticReports 側を掘る遠回りになる(受け手報告)
                    unusableReason = "the device disappeared (offline/not found)"
                        + (worker.connection.physical ? ""
                           : EmulatorLog.dropoutHint(deviceName: worker.connection.deviceName))
                    unusableCause = .deviceGone
                } else if !worker.connection.physical, await deviceFrozen(serial) {
                    // 凍結判定はエミュレータ限定(閾値が解像度依存。ProfileWorkerFactory の
                    // excludeOrRepairBlankScreenWorkers と同じ理由)
                    unusableReason = "a frozen screen"
                    unusableCause = .frozen
                }
            }
            // **iOS はドライバ不達(driverUnreachable)も .failed と同じ経路を通す**
            // (下の requeuesWithoutRetiring は iOS をプローブの後でしか通さない。ここを .failed
            // だけに限ると、driverUnreachable を名乗った失敗だけブリッジ生存プローブを飛ばして
            // しまい、iOS の既存挙動 —— 起動し直し→復活→再キュー —— が起きなくなる)
            if unusableReason == nil, outcome == .failed || outcome == .driverUnreachable,
               worker.platform == "ios",
               let verdict = await bridgeUnreachable(worker) {
                switch verdict {
                case .identityMismatch(let mismatch):
                    unusableReason = "a bridge that now belongs to another device (\(mismatch))"
                    unusableCause = .bridgeTakenOver
                case .unreachable(let detail):
                    unusableReason = detail.map { "an unreachable bridge (\($0))" }
                        ?? "an unreachable bridge"
                    unusableCause = .bridgeUnreachable
                }
            }
            // **Android のドライバ不達で、デバイスは生きている**(消失でも凍結でもない)= ブリッジだけが
            // 一過性に切れた形(adb kill-server・ブリッジの force-stop・adb: device offline・実機の
            // 再起動で実測)。Android のブリッジは次の要求で黙って張り直されるので事後プローブでは
            // 健全に見え、落ちたシナリオが赤のまま残っていた。**ここまで来た = デバイスは生きている**ので、
            // 結果を捨てて振り直し、ワーカーは残す。**iOS もここへ入る** —— 上の
            // bridgeUnreachable がブリッジの生存を確かめた後なので「デバイスは生きている」が成り立つ
            // (死んでいれば unusableReason が入り、離脱→起動し直し→再キューの既存経路へ行く)
            // **ただし連続失敗はブレーカに数える** —— 数えないと、ブリッジを二度と張り直せないデバイス
            // (adb には見えていて凍結もしていない形)が離脱もせずに残り、後続のシナリオの
            // 再キュー枠(1本につき1回)を1つずつ焼き潰す。ここで `.trip` したら振り直さずに
            // 下の離脱経路へ落とす(`environmentFault` は数えないまま = あちらはデバイスではなく
            // 環境ノイズという実測に基づく既存の判断)
            if unusableReason == nil, outcome == .driverUnreachable,
               ScenarioRunner.requeuesWithoutRetiring(outcome: outcome) {
                let verdict = breaker.recordFailure(runPasses: await runPasses.snapshot())
                await persistStreak(breaker, key: streakKey)
                switch ScenarioRunner.unreachableLaneAction(verdict: verdict) {
                case .retire(let reason):
                    unusableReason = reason
                    unusableCause = .consecutiveFailures
                case .requeue:
                    let requeued = await discardAndRequeue(item, worker: worker, queue: queue,
                                                           reason: "an unreachable bridge",
                                                           avoidingThisLane: true,
                                                           cause: .bridgeUnreachable)
                    if requeued {
                        await progressState?.laneIdled(laneKey: progressLaneKey)
                    } else {
                        await progressState?.scenarioFinished(laneKey: progressLaneKey, passed: false)
                    }
                    if !requeued { failed += await failureCount(item, worker: worker, queue: queue) }
                    continue
                }
            }
            // サーキットブレーカ: 凍結/消失に当てはまらなくても連続失敗が閾値に達し、その間に別の
            // レーンが通っていれば不調ワーカーとして離脱。誰も通っていなければ残す(全レーンが同時に
            // 落ちている = デバイスではなく run の問題。離脱させると revive を使い切って残りが未実行で赤になる)
            // 最後に通ってから別のデバイスでも落ちたシナリオ(どこでも落ちる赤)は、このレーンの不調の証拠に数えない
            // デバイスに触れずに落ちたと確定できる失敗だけのシナリオも数えない(WorkerCircuitBreaker.countsAsLaneFailure)
            if unusableReason == nil,
               WorkerCircuitBreaker.countsAsLaneFailure(failedStepKinds: failedStepKinds.withLock { $0 }),
               await witnessOutcome(unit: item.unitKey, worker: streakKey, passed: false) {
                let verdict = breaker.recordFailure(runPasses: await runPasses.snapshot())
                await persistStreak(breaker, key: streakKey)
                switch verdict {
                case .keep:
                    break
                case .trip(let consecutive):
                    // 数えているのはこのレーンで赤になったシナリオの数(別のシナリオの赤も数える)。端末の故障とは言わない
                    unusableReason = "\(consecutive) consecutive scenario failures on this lane"
                        + Self.carriedNote(breaker.carriedFailures)
                    unusableCause = .consecutiveFailures
                case .held(let consecutive, let announce):
                    if announce {
                        let message = "\(consecutive) consecutive scenario failures on this lane"
                            + Self.carriedNote(breaker.carriedFailures)
                            + " while no other lane"
                            + " has passed since the streak began — keeping the lane (a lane is retired"
                            + " for consecutive failures only when another lane passed meanwhile)"
                        continuation.yield(.workerLog(worker: worker.label, message: "⚠️ \(message)"))
                        await anomalies.add(WorkerAnomalyRecord(
                            kind: "circuitHeld", worker: Self.workerID(worker), label: worker.label,
                            scenarioID: item.info.id, reason: message, cause: .consecutiveFailures))
                    }
                }
            }
            if let reason = unusableReason {
                return await retireUnusable(item, worker: worker, queue: queue, reason: reason, cause: unusableCause,
                                            failed: failed, progressLaneKey: progressLaneKey, leaseKey: leaseKey,
                                            keepsFailedResult: ScenarioRunner.keepsFailedResultOnRetire(
                                                outcome: outcome, cause: unusableCause))
            }
            await progressState?.scenarioFinished(laneKey: progressLaneKey, passed: false)
            failed += await failureCount(item, worker: worker, queue: queue)
        }
        // もうシナリオを取らないので、切り離しの判定で「引き取れるレーン」に数えない(片付けの間も含めて)
        renderingBook.withLock { $0.leave(laneKey: progressLaneKey) }
        // キューを掃き切ったデバイスだけが片付ける(離脱は上で return 済み・中断中は新しい子を起こさない。
        // 遅延参加の中止では片付ける = 利用者が止めたのではない)
        if await !stoppedByUser() {
            let outcomes = await ScenarioHost.runDeviceTearDowns(
                project: project, connection: worker.connection,
                deviceSession: deviceSessions.session(for: BroadcastPlan.laneKey(of: worker)),
                settings: settings, reportDir: reportDir.path, dryRun: false,
                appPath: appTargets[worker.platform]?.packagePath(physical: worker.connection.physical),
                appName: appTargets[worker.platform]?.appName,
                appBundleID: appBundleIDs[worker.platform],
                registerChildProcess: registerChildProcess)
            for outcome in outcomes {
                continuation.yield(.workerLog(worker: worker.label, message: ScenarioHost.describe(outcome)))
            }
        }
        if let leaseKey { await runLeases.release(leaseKey) }
        // 切り出し(stopRecording)より前に閉じる —— 最後のワーカーの切り出しこそが待ち時間の本体
        await closeTestingSlot()
        await stopRecording(worker, leaseKey: leaseKey)
        return .completed(failed)
    }

    private func closeTestingSlot() async {
        if await testingSlots.close() {
            continuation.yield(.recordingFinalizing)
        }
    }

    /// run-lease / 録画 lease のキー(iOS = シミュレータ UDID / Android = adb serial)
    private static func leaseKey(_ worker: RunWorker) -> String? {
        worker.connection.serial ?? worker.connection.udid
    }

    /// RecordingLease の削除は停止指示と同時に行う。lease 削除後に videoRecording?.stop で実際の停止へ進む
    /// (クリップの切り出しは全ワーカーの終了後に videoRecording?.finish がまとめて行う)
    private func stopRecording(_ worker: RunWorker, leaseKey: String?) async {
        if let leaseKey {
            await recordingLeases.release(leaseKey)
        }
        await videoRecording?.stop(worker)
    }
}
