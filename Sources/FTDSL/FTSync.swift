// DSL 専用スレッド(協調スレッドプール外)から async の StepExecutor/AppDriver へ橋渡しする同期ファサード。
// ブロックするのは DSL スレッドのみで、async 側(URLSession/Process/FoundationModels)は
// このスレッドを必要としないためデッドロックしない。万一のハングに備え待機に上限タイムアウトを設ける。

import Foundation
import FTCore
import Synchronization

enum FTSync {
    /// コマンド 1 回の上限待機秒数
    static var commandTimeout: TimeInterval {
        get { commandTimeoutStorage.withLock { $0 } }
        set { commandTimeoutStorage.withLock { $0 = newValue } }
    }
    private static let commandTimeoutStorage = Mutex<TimeInterval>(RunTunables().commandTimeout)

    /// DSL スレッドの op を協調プールへ渡す包み。@unchecked の根拠 = DSL スレッドは op の完了まで
    /// semaphore で止まっている(op の捕捉物に同時に触る者がいない)。**例外は時間切れ** —— cancel の後、
    /// 巻き戻りを `cancelUnwindGraceSeconds` まで待つ。待ち切れなかった回だけ DSL スレッドの次の命令と重なりうる
    /// (`TimeoutReport.unwindOverran` で失敗文に言う)
    private struct UncheckedOperation<T>: @unchecked Sendable {
        let body: () async -> T
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }

    /// **タスクが実際に走り出すまでの待ち**(協調スレッドプールの空き待ち)を持ち帰る箱。
    /// 壁時計の締め切りは順番待ちの時間も数えてしまうので、それが何割かを測れないと
    /// 締め切りの妥当性を判断できない(実測: 20 秒超のステップは
    /// snapshot/action/wait のどれにも計上されない時間が 99.7% を占めていた)。
    /// 別スレッドから書くのでロックで守る。**最初の1回だけ**記録する。
    final class ScheduleDelay: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int?
        func record(_ ms: Int) { lock.lock(); if value == nil { value = ms }; lock.unlock() }
        var milliseconds: Int? { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// 打ち切った op の巻き戻りを待つ上限(秒)。根拠と、親の無出力の監視(`ScenarioIdleBudget`)が足していることは
    /// `RunTunables.commandCancelUnwindSeconds` の doc(子は `apply` で親と同じ値を受け取る = 監視の上限と食い違わせない)
    static var cancelUnwindGraceSeconds: TimeInterval {
        get { cancelUnwindStorage.withLock { $0 } }
        set { cancelUnwindStorage.withLock { $0 = newValue } }
    }
    private static let cancelUnwindStorage = Mutex<TimeInterval>(RunTunables().commandCancelUnwindSeconds)

    /// 子が親から受けた RunTunables のうち FTSync の上限を写す(コマンドの上限と止まり切る待ちを別々に写し忘れない)
    static func apply(_ tunables: RunTunables) {
        commandTimeout = tunables.commandTimeout
        cancelUnwindGraceSeconds = tunables.commandCancelUnwindSeconds
    }

    /// 時間切れの後始末の事実を呼び手へ持ち帰る箱(書くのは DSL スレッド = run の中だけ)
    final class TimeoutReport: @unchecked Sendable {
        /// cancel の後 `unwindGrace` まで待っても op が戻らなかった
        var unwindOverran = false
        /// 打ち切りを決めた時刻(巻き戻りの待ちの前)。失敗の時刻 `at` に使う = 待った分だけ録画の再生位置をずらさない
        var decidedAt: Date?
    }

    /// 打ち切ったステップの失敗文。止まり切らなかった回は、後続(afterEach を含む)と重なりうることを言う
    static func timedOutMessage(_ report: TimeoutReport) -> String {
        "the command timed out (\(Int(commandTimeout))s)"
            + (report.unwindOverran
                ? "; it was still running \(Int(cancelUnwindGraceSeconds))s after it was stopped, so the"
                    + " steps after it (including afterEach) may have overlapped with it"
                : "")
    }

    /// タイムアウト時は nil。**そのとき op は必ず cancel する** — 放置すると諦めたはずの
    /// tap/snapshot が**後続ステップの最中にブリッジへ着弾**し、記録に残らないまま画面を動かす
    /// (原因不明の一発ずれになる)。cancel は通信(cancel 対応の `URLSession.data(for:)`)には届くので、毎周通信を挟むループは
    /// そこで抜ける(`try? await Task.sleep` は cancel を握りつぶして眠りを明けるだけ = ループを止めるのは通信の失敗のほう)。
    /// 相手が cancel を見ない処理(Process 実行等)は走り切るので、戻る前に `unwindGrace` まで止まり切るのを待つ。
    ///
    /// **`DeadlineExclusion` に積まれた分だけ締め切りを延ばす**(OCR 近道のコンパイル待ち等、
    /// ツールの都合で払った時間を締め切りから外すため)。延長できるのは実際に差し引かれた分だけ
    /// —— 打ち切りの意味は変えない。`op` を始める前に基準点(snapshot)を取り、タイムアウトの
    /// たびに「そこから新たに差し引かれた分」だけ待ちを継ぎ足す(継ぎ足しが 0 なら本当のタイムアウト)
    static func run<T>(timeout: TimeInterval = FTSync.commandTimeout,
                       scheduleDelay: ScheduleDelay? = nil,
                       timeoutReport: TimeoutReport? = nil,
                       unwindGrace: TimeInterval = FTSync.cancelUnwindGraceSeconds,
                       _ op: @escaping () async -> T) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box<T>()
        let queuedAt = ContinuousClock().now
        let exclusionSnapshot = DeadlineExclusion.snapshot()
        let work = UncheckedOperation(body: op)
        let task = Task.detached(priority: .userInitiated) {
            if let scheduleDelay {
                // **最初の1命令が走った時刻**。ここまでの差は「順番待ち」で、ステップは1命令も
                // 実行していない —— 締め切りに数えてよい時間かどうかの判断材料になる
                let waited = ContinuousClock().now - queuedAt
                scheduleDelay.record(Int((waited / .milliseconds(1)).rounded()))
            }
            box.value = await work.body()
            semaphore.signal()
        }
        var remaining = timeout
        var grantedExtraSeconds: TimeInterval = 0
        while true {
            guard semaphore.wait(timeout: .now() + max(0, remaining)) == .success else {
                let excludedSeconds = DurationConversion.seconds(DeadlineExclusion.excluded(since: exclusionSnapshot))
                let newExtra = excludedSeconds - grantedExtraSeconds
                guard newExtra > 0 else {
                    timeoutReport?.decidedAt = Date()
                    task.cancel()
                    // **止まり切るまで待ってから戻る**(上限つき)。値は捨てる(打ち切りの意味は変えない)
                    if semaphore.wait(timeout: .now() + max(0, unwindGrace)) != .success {
                        timeoutReport?.unwindOverran = true
                    }
                    return nil
                }
                grantedExtraSeconds = excludedSeconds
                remaining = newExtra
                continue
            }
            return box.value
        }
    }


    /// throwing 版(タイムアウト時は nil)
    static func runThrowing<T>(timeout: TimeInterval = FTSync.commandTimeout,
                               _ op: @escaping () async throws -> T) -> Result<T, Error>? {
        run(timeout: timeout) {
            do { return .success(try await op()) } catch { return .failure(error) }
        }
    }
}
