// ProvisionLockHold.swift
// 供給の ProvisionLock を「全ブリッジのポート確保が揃うまで」+「adopt の起動し直し中」だけ握る持ち手(呼び手は BridgeProvisioner)

import Foundation
import Synchronization

/// 外側の ProvisionLock の早期解放(`PortClaimBarrier` 完了)と、adopt が止めて起動し直す区間
/// (`launcher.stopAndWait()` で pid ファイルが消えてから、起動し直しが pid を書き直す = claimed まで)を調停する。
/// この区間がロックの外だと、別プロセスの採番が消えた pid を空きと読み、同じポートへ別デバイスのブリッジを起動する。
/// - **新しい ProvisionLock を無条件に取らない**: flock は open ごとなので外側と競合する。外側は全 claim が揃うまで
///   解けず、inapp-boost の1台は xcuitest → inapp の直列で inapp の claim がまだ撃たれていない = 永久に待つ。
///   ここでは外側を握ったまま `beginRestart` の数だけ解放を遅らせ、**すでに解けていたときだけ**取り直す
///   (取り直しの待ちは他プロセスの保持にだけ依存し、このプロセスは何も握っていないのでデッドロックしない)
/// - 数の増減と解放の判定は同じ Mutex の中。`beginRestart` は解放の判定より前に数を足すので、
///   「解ける直前に確認して取り直さない」競合は無い
final class ProvisionLockHold: Sendable {
    /// 解放してよい条件。barrier 完了 かつ 起動し直し中が 0、または供給の終了
    static func shouldRelease(barrierDone: Bool, restarts: Int, finished: Bool) -> Bool {
        finished || (barrierDone && restarts == 0)
    }

    private struct State {
        var lock: ProvisionLock?
        var restarts = 0
        var barrierDone = false
        var finished = false
        var reacquire: Task<ProvisionLock?, Never>?
    }

    private let state: Mutex<State>
    private let stateDir: URL
    private let lockName: String

    init(held: ProvisionLock, stateDir: URL, lockName: String = "provision.lock") {
        state = Mutex(State(lock: held))
        self.stateDir = stateDir
        self.lockName = lockName
    }

    /// PortClaimBarrier 完了の合図
    func barrierCompleted() { update { $0.barrierDone = true } }

    /// 供給の終了(defer から)。以後は取り直さない
    func finish() { update { $0.finished = true } }

    /// adopt の止める直前に呼ぶ。戻った時点でロックを保持している(取り直せなければ保持せず進む = 従来と同じ)
    func beginRestart(onWait: (@Sendable (String) -> Void)? = nil) async {
        let task: Task<ProvisionLock?, Never>? = state.withLock { s in
            s.restarts += 1
            guard s.lock == nil, !s.finished else { return nil }
            if let pending = s.reacquire { return pending }
            let dir = stateDir, name = lockName
            let made = Task<ProvisionLock?, Never> {
                guard let fresh = try? ProvisionLock(stateDir: dir, lockName: name) else { return nil }
                await fresh.acquire(onWait: onWait)
                return fresh
            }
            s.reacquire = made
            return made
        }
        guard let task, let fresh = await task.value else { return }
        let surplus: ProvisionLock? = state.withLock { s in
            s.reacquire = nil
            if s.finished { return fresh }
            if s.lock == nil { s.lock = fresh }
            return nil
        }
        surplus?.release()  // 冪等
    }

    /// `beginRestart` と対。起動し直しの claimed 到達か失敗で呼ぶ(呼び手が 1 回に絞る)
    func endRestart() { update { $0.restarts -= 1 } }

    var isHolding: Bool { state.withLock { $0.lock != nil } }

    private func update(_ change: (inout State) -> Void) {
        let toRelease: ProvisionLock? = state.withLock { s in
            change(&s)
            guard Self.shouldRelease(barrierDone: s.barrierDone, restarts: s.restarts, finished: s.finished),
                  let lock = s.lock else { return nil }
            s.lock = nil
            return lock
        }
        toRelease?.release()
    }
}
