// ScenarioRunner.swift
// 1シナリオの実行(サブプロセス起動+イベント変換)と結果の仕分け。オーケストレーション全体は RunOrchestrator.swift

import Foundation

/// 1 シナリオの実行(サブプロセス起動+イベント変換)。
/// CLI の逐次実行と RunOrchestrator のワーカーの両方がここを通る。
public enum ScenarioOutcome: Sendable, Equatable {
    case passed, failed, frozen
    /// 子が対象外を宣言した(passed == true と対)。レーンの健全性は passed と同じ扱いで、数えるときだけ別
    case notApplicable
    /// **デバイス側の一過性の故障**でテストが落ちた(コードの失敗ではない)。振り直す
    case environmentFault
    /// 失敗ステップの `failureKind` が `driverUnreachable`(ブリッジ不達)だった。
    /// **OS で扱いが割れる** —— Android は environmentFault と同じ振り直し対象(runWorker 側の
    /// `requeuesWithoutRetiring`)。iOS は先に `.failed` と同じ事後プローブ(bridgeUnreachable)を
    /// 通し(ここで早期に振り直すと起動し直しが起きなくなる)、ブリッジが生きていたときだけ振り直す
    case driverUnreachable
    /// 子がアプリのクラッシュの証拠(`appCrash`)を持って落ちた。**振り直さず赤のまま残す** ——
    /// in-app ブリッジはアプリの中に居るので、アプリの死はブリッジ不達としても現れる。
    /// `.failed` / `.driverUnreachable` に混ぜると事後プローブが「不達」と言って結果ごと捨て、
    /// 2回目が緑ならクラッシュするアプリが常に緑になる。
    /// 事後プローブのうちデバイス消失・凍結は `.failed` と同じに通す(ブリッジ生存プローブだけ飛ばす)
    case appCrashed
    /// 失敗ステップの `failureKind` が `appInBackground`(アプリが背面にあり、iOS に一時停止された in-app ブリッジが答えなかった。
    /// XCUITest の照会で確かめた事実)。**振り直さず赤のまま残し、ブリッジの生存プローブは飛ばす**(appCrashed と同じ扱い)。
    /// 同じシナリオにブリッジ不達(`driverUnreachable`)もあればそちらになる(`outcome` の優先順位)——
    /// 止まったアプリの中のブリッジは答えないので、プローブは「不達」と言ってレーンを離脱させ、同じ失敗を振り直していた
    case appInBackground
}

/// 「テストではなくデバイスが壊れていた」と機械的に言い切れる失敗のしるし。
/// **ここに足すのは、アサーション失敗と構造的に区別できるものだけ** ——
/// ドライバが返した基盤側のエラーで、同じコードを別デバイスや少し後に走らせれば通るもの。
/// 判定を広げると本物の失敗を skipped に隠すことになる
enum EnvironmentFault {
    /// XCUITest の a11y 基盤が一時的に応答しない。**ブリッジ供給直後・アプリ入れ替え直後**に
    /// 同時刻クラスタで出て、再実行で必ず消える(2回・8件と6件を手で判定した)。
    /// docs/verification/judgment.md「デバイス基盤の一過性エラーは「テストの失敗」と数えない」
    static let markers = ["kAXErrorAPIDisabled"]

    static func matches(_ detail: String?) -> Bool {
        guard let detail else { return false }
        return markers.contains { detail.contains($0) }
    }
}

public enum ScenarioRunner {
    /// 戻り値: 実行結果。進捗は onEvent で通知される
    public static func runOne(project: TestProject, item: ScenarioRunItem, worker: RunWorker,
                              deviceSession: RunDeviceSession,
                              settings: ScenarioExecutionSettings, reportDir: URL,
                              debug: ScenarioDebugOptions? = nil,
                              recorder: RunRecorder? = nil,
                              installHandler: (@Sendable (RunWorker, String?) async
                                               -> (ok: Bool, message: String))? = nil,
                              appName: String? = nil,
                              appBundleID: String? = nil,
                              appPath: String? = nil,
                              /// ScenarioHost.run(hostNotices:) への素通し
                              hostNotices: [String] = [],
                              /// ScenarioHost.run(registerChildProcess:) への素通し
                              /// (RunOrchestrator が中断口として保持する同名プロパティ参照)
                              registerChildProcess: (@Sendable (Process) -> @Sendable () -> Void)? = nil,
                              /// ScenarioRecording.humanOperationsStateDir への素通し
                              humanOperationsStateDir: URL? = nil,
                              /// 子の step / scenarioFinished が運ぶ `actions`(デバイスへ送った操作の回数の増分)を run 進捗の台帳へ渡す。nil = 台帳を持たない経路
                              onActions: (@Sendable (Int) -> Void)? = nil,
                              /// ScenarioHost.run(onEventLogStarted:) への素通し(run 進捗の台帳のレーンへイベントログのパスを載せる)
                              onEventLogStarted: (@Sendable (URL) -> Void)? = nil,
                              /// ScenarioHost.run(stillFramesDir:) への素通し(静止画方式の録画)
                              stillFramesDir: URL? = nil,
                              onEvent: @escaping (RunEvent) -> Void) async -> ScenarioOutcome {
        onEvent(.flowStarted(worker: worker.label, flowURL: item.url,
                             flowName: item.info.id, isDirty: false))

        // worker id 形式は ApiRunCommand.swift の workerID 変換表・workersReadyInfo と同一規則
        let recording = recorder.map {
            ScenarioRecording(recorder: $0, worker: Self.recordingWorker(worker),
                              title: item.info.title, humanOperationsStateDir: humanOperationsStateDir)
        }
        var reportURL: URL?
        var fmUsage: FMUsageRecord?
        var appCrash: AppCrashRecord?
        var notApplicableReason: String?
        var frozen = false
        var environmentFault = false
        var driverUnreachableFailure = false
        var appInBackgroundFailure = false
        let passed = await ScenarioHost.run(
            project: project, scenarioID: item.info.id,
            // 値はプロファイルの variants の解決結果(展開は同じプロファイルから作るので必ず引ける)
            variant: item.variant.map { name in
                settings.variants.first { $0.name == name } ?? ResolvedVariant(name: name, appearance: nil, textSize: nil, orientation: nil)
            },
            connection: worker.connection,
            deviceSession: deviceSession,
            classHasBeforeAll: item.info.beforeAll,
            scenarioTimeoutOverride: item.info.scenarioTimeout,
            settings: settings, reportDir: reportDir.path,
            debug: debug, recording: recording,
            installHandler: installHandler.map { handler in
                { (path: String?) async -> (ok: Bool, message: String) in await handler(worker, path) }
            },
            appPath: appPath, appName: appName, appBundleID: appBundleID,
            hostNotices: hostNotices,
            registerChildProcess: registerChildProcess, stillFramesDir: stillFramesDir,
            onEventLogStarted: onEventLogStarted) { event in
            if event.kind == "step" || event.kind == "scenarioFinished", let actions = event.actions {
                onActions?(actions)
            }
            switch event.kind {
            case "sceneStarted":
                onEvent(.sceneStarted(worker: worker.label, flowURL: item.url,
                                      scene: event.scene ?? 0,
                                      sceneTitle: event.sceneTitle ?? ""))
            case "step":
                // **デバイス基盤の一過性エラーは「テストの失敗」として数えない**(振り直す)
                if event.status == "failed", EnvironmentFault.matches(event.detail) {
                    environmentFault = true
                }
                // ドライバ(ブリッジ)不達。文言の一致ではなく `StepFailureKind`(DriverError の
                // case で仕分け済み)で判定する
                if event.status == "failed",
                   event.failureKind == StepFailureKind.driverUnreachable.rawValue {
                    driverUnreachableFailure = true
                }
                if event.status == "failed",
                   event.failureKind == StepFailureKind.appInBackground.rawValue {
                    appInBackgroundFailure = true
                }
                onEvent(.step(worker: worker.label, flowURL: item.url,
                              result: stepResult(from: event)))
            case "sceneFinished":
                onEvent(.sceneFinished(worker: worker.label, flowURL: item.url,
                                       scene: event.scene ?? 0,
                                       sceneTitle: event.sceneTitle ?? "",
                                       passed: event.passed ?? false,
                                       skipped: event.skipped ?? false))
            case "paused":
                onEvent(.flowPaused(worker: worker.label, flowURL: item.url,
                                    index: event.index ?? 0,
                                    description: event.description ?? "",
                                    file: event.file, line: event.line))
            case "fixSuggestion":
                // 「💡 修正提案: …」合成 step 行(実際のコマンド結果ではない。synthetic: true の
                // 意味は StepResult.synthetic 参照)
                onEvent(.step(worker: worker.label, flowURL: item.url,
                              result: StepResult(index: event.index ?? 0,
                                                 description: "💡 Suggested fix: \(event.detail ?? "")",
                                                 status: .passed, synthetic: true)))
                onEvent(.fixSuggestion(worker: worker.label, flowURL: item.url,
                                       scenarioID: event.scenario ?? item.info.id,
                                       command: event.description,
                                       file: event.file, line: event.line,
                                       oldSelector: event.oldSelector,
                                       newSelector: event.newSelector,
                                       message: event.detail ?? ""))
            case "scenarioFinished":
                reportURL = event.reportPath.map { URL(fileURLWithPath: $0) }
                fmUsage = event.fm
                appCrash = event.appCrash
                notApplicableReason = event.notApplicableReason
            case "deviceFrozen":
                frozen = true
            case "log":
                if let message = event.message, !message.isEmpty {
                    onEvent(.step(worker: worker.label, flowURL: item.url,
                                  result: StepResult(index: 0, description: message,
                                                     status: .passed)))
                }
            default:
                break
            }
        }

        let outcome = Self.outcome(passed: passed, frozen: frozen,
                                   environmentFault: environmentFault,
                                   driverUnreachable: driverUnreachableFailure,
                                   notApplicable: notApplicableReason != nil,
                                   appCrashed: appCrash != nil,
                                   appInBackground: appInBackgroundFailure)
        onEvent(.flowFinished(worker: worker.label, flowURL: item.url, passed: frozen ? false : passed,
                              reportURL: reportURL, fm: fmUsage, appCrash: appCrash,
                              notApplicableReason: outcome == .notApplicable ? notApplicableReason : nil))
        return outcome
    }

    /// 結果 JSON(`ScenarioRunRecord.worker`)に載る書き手の名。**`RunRecorder.discardLast(worker:)` に
    /// 渡すのもこれ**(同じ文字列でないと、取り消しが別のデバイスの記録を消す)
    public static func recordingWorker(_ worker: RunWorker) -> String {
        "\(worker.platform):\(worker.logicalName ?? worker.label)"
    }

    /// 実行結果の確定(純粋関数)。**優先順位に意味がある**: 画面凍結 > 合否 > アプリのクラッシュ >
    /// 環境の一過性エラー > ドライバ不達 > アプリが背面。凍結はワーカーごと使えないので先に判定し、合否は環境エラー/ドライバ不達で
    /// 上書きしない(途中のステップがそれらでも、最終的に通ったならテストとしては合格)
    static func outcome(passed: Bool, frozen: Bool, environmentFault: Bool,
                        driverUnreachable: Bool, notApplicable: Bool,
                        appCrashed: Bool = false, appInBackground: Bool = false) -> ScenarioOutcome {
        if frozen { return .frozen }
        if passed { return notApplicable ? .notApplicable : .passed }
        if appCrashed { return .appCrashed }
        if environmentFault { return .environmentFault }
        // ブリッジ不達が同じシナリオにあれば、そちら(生存プローブ・振り直し)を優先する(後始末の段の背面の断りで隠さない)
        if driverUnreachable { return .driverUnreachable }
        return appInBackground ? .appInBackground : .failed
    }

    /// ワーカーを外すとき、シナリオ自身の判定で確定した赤(`.failed`)を捨てて再キューしない。
    /// 捨てると、行き先のワーカーが居ない(他レーンが完了済み・蘇生失敗)ときに元の失敗が
    /// run.json から消え「no usable workers」の未実行に置き換わる。ブリッジ/デバイスの喪失が
    /// 赤の原因か後かは見分けられないので、赤は事実としてそのまま残す。
    /// `.driverUnreachable` 等(判定が出ていない)と、連続失敗・凍結の離脱は従来どおり再キューする
    static func keepsFailedResultOnRetire(outcome: ScenarioOutcome, cause: WorkerAnomalyCause?) -> Bool {
        guard outcome == .failed else { return false }
        switch cause {
        case .bridgeUnreachable, .bridgeTakenOver, .deviceGone:
            return true
        default:
            return false
        }
    }

    /// **失敗を結果ごと捨てて振り直し、ワーカーは離脱させない**か(純粋関数)。
    /// **driverUnreachable の呼び出しは事後プローブ(消失・凍結)の後** —— デバイスが生きていると
    /// 分かってから訊く(デバイスが消えた形も同じ failureKind で来るため。呼び出し側のコメント参照)。
    /// environmentFault は OS 問わず対象(既存)。driverUnreachable は **Android だけ**対象 —— Android のブリッジは
    /// 次の要求で黙って張り直されるため事後プローブ(deviceUnreachable/deviceFrozen)では拾えず、
    /// 落ちたシナリオが赤のまま残っていた(実測: adb kill-server 等で5本・force-stop で1本・
    /// device offline で1本・実機再起動で1本)。**iOS はここで拾わない** —— 下流の
    /// bridgeUnreachable プローブ→ワーカー離脱→復帰→再キューの経路(既存)をそのまま通す必要があり、
    /// ここで早期に振り直すとブリッジの起動し直しが起きなくなる
    /// **iOS でこれが呼ばれるのは事後プローブ(bridgeUnreachable)がブリッジの生存を確かめた後だけ**
    /// (呼び出し側の順序。Android にはその工程が無い)。生きているデバイスで一過性に切れた 1 本を
    /// 赤のまま残さず、デバイスは残して振り直す —— ここを通さないと iOS は
    /// Wi-Fi の瞬断・アプリが背面に回った回が赤になるか、生きたランナーの起動し直しになる
    static func requeuesWithoutRetiring(outcome: ScenarioOutcome) -> Bool {
        switch outcome {
        case .environmentFault:
            return true
        case .driverUnreachable:
            return true
        case .passed, .notApplicable, .failed, .frozen, .appCrashed, .appInBackground:
            return false
        }
    }

    /// ブリッジ不達で振り直すデバイスの扱い(純粋関数)。**連続失敗がブレーカの閾値に達したら振り直さない**
    /// —— ブリッジを二度と張り直せないデバイス(adb には見えていて凍結もしていない形)が離脱せずに残ると、
    /// 後続のシナリオの再キュー枠(1本につき1回)を1つずつ焼き潰す。`held`(その streak の間に
    /// 他のレーンが1本も通っていない = デバイスではなく run の問題)は離脱させない既存の規律どおり
    enum UnreachableLaneAction: Equatable {
        case requeue
        case retire(reason: String)
    }

    static func unreachableLaneAction(verdict: WorkerCircuitBreaker.Verdict) -> UnreachableLaneAction {
        switch verdict {
        case .trip(let consecutive):
            return .retire(reason: "\(consecutive) consecutive worker failures")
        case .keep, .held:
            return .requeue
        }
    }

    /// ScenarioEvent(step)→ StepResult。scene/sceneTitle/section は構造化フィールドのまま写す。
    /// passedViaFallback/healed の detail の扱いは FlowLocator.raw(Flow.swift)参照
    static func stepResult(from event: ScenarioEvent) -> StepResult {
        let status: StepResult.Status
        switch event.status {
        case "passed":
            status = .passed
        case "passedViaFallback":
            status = .passedViaFallback(FlowLocator(raw: event.detail ?? ""))
        case "healed":
            status = .healed(FlowLocator(raw: event.detail ?? ""))
        case "failed":
            status = .failed(event.detail ?? "")
        case "inconclusive":
            status = .inconclusive(event.detail ?? "")
        default:
            status = .skipped(event.detail ?? "")
        }
        // 時間内訳。サブプロセスの ScenarioEvent に durationMs が無ければ
        // 未計測のステップ(dry-run・スキップ等)なので timing 自体を nil のままにする
        let timing = event.durationMs.map {
            StepTiming(durationMs: $0, snapshotMs: event.snapshotMs,
                      actionMs: event.actionMs, waitMs: event.waitMs,
                      scheduleDelayMs: event.scheduleDelayMs, cpuMs: event.cpuMs,
                      ioBlockedMs: event.ioBlockedMs,
                      stallMs: event.stallMs, poolStallMs: event.poolStallMs,
                      guardMs: event.guardMs, ocrMs: event.ocrMs,
                      pacingMs: event.pacingMs)
        }
        return StepResult(index: event.index ?? 0, description: event.description ?? "",
                          status: status, scene: event.scene, sceneTitle: event.sceneTitle,
                          section: event.section, timing: timing, at: event.at,
                          command: event.command, failureKind: event.failureKind,
                          notes: event.notes, guarded: event.guarded,
                          response: event.response)
    }
}
