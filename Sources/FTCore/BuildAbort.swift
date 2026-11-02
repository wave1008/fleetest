import Foundation
import Synchronization

/// run の間に走るビルド(`swift build`・`xcodebuild build-for-testing`・`InAppBridge/build.sh`)を、中断で止める登録簿。
/// 呼び手は `Shell.run(..., abortable: true)` だけ(登録・解除は `Shell.runRaw`)。
/// - 立つのは `RunInterruptState.requestStop`(fleetest の run / api run)だけ。MCP・CLI の単発コマンドは立てない = 影響なし
/// - **立った後に起こすビルドは起こした直後に止める**(供給の再試行が、止めたビルドを撃ち直さない)
/// - ビルドは後始末を持たない外部プロセスなので SIGKILL へ上げてよい(process-lifecycle.md)。段の境目を待たずに
///   ビルドの `Shell.run` が非0で戻り、呼び手が投げて `RunExitGuard` の出口(片付け・ロックの解放)を通る
public enum BuildAbort {
    private struct State {
        var aborted = false
        var running: Set<pid_t> = []
    }
    private static let state = Mutex(State())

    public static var isAborted: Bool { state.withLock { $0.aborted } }

    /// ビルドの子を登録する。**既に中断済みなら false**(呼び手が即止める)
    static func register(pid: pid_t) -> Bool {
        state.withLock { s in
            if s.aborted { return false }
            s.running.insert(pid)
            return true
        }
    }

    static func unregister(pid: pid_t) {
        state.withLock { _ = $0.running.remove(pid) }
    }

    /// 走っているビルドへ合図を送り、以後のビルドを断る。戻り値は合図を送った数。
    /// 合図は子のプロセスグループへ送る(pgid == 子の pid なので孫まで届く。`Shell.swift` の `killpg` と同じ)。`killpg` が失敗したときだけ直下の子へ送る
    /// `kill: false` = SIGTERM(1回目の中断)/ `true` = SIGKILL(SIGTERM を無視して残ったビルドへ)
    @discardableResult
    public static func abortAll(kill: Bool) -> Int {
        let pids = state.withLock { s -> [pid_t] in
            s.aborted = true
            return Array(s.running)
        }
        for pid in pids {
            let sig = kill ? SIGKILL : SIGTERM
            if killpg(pid, sig) != 0 { _ = Foundation.kill(pid, sig) }
        }
        return pids.count
    }

    /// テスト用: 立てた印と登録簿を戻す
    public static func resetForTesting() {
        state.withLock { $0 = State() }
    }
}
