// PortClaimBarrier.swift
// 並行する供給のポート確保の待ち合わせ(呼び手は BridgeProvisioner)

import Foundation
import FTCore

/// **ポート確保(pid ファイル/記録の書き込み)まで**を数える関門。全ブリッジが「確保済み or 失敗」に
/// なった時点で ProvisionLock を解く —— ready 待ち(実測 7〜28 秒)をロックの外へ出すため。
/// これが無いと、ワーカーが 2 つあっても供給は常に 1 台ずつになる(実測: iOS 5 本の
/// 供給 95 秒がすべて直列)。**撃ち漏らすとロックが解放されない**ので、呼び出し側は成否を問わず
/// 必ず 1 回通すこと(BridgeProvisioner.executeDevice の ClaimOnce)
actor PortClaimBarrier {
    private var remaining: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(expected: Int) { remaining = max(0, expected) }

    func claimed() {
        guard remaining > 0 else { return }
        remaining -= 1
        guard remaining == 0 else { return }
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    func waitAll() async {
        guard remaining > 0 else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// 1 ブリッジぶんの合図を 1 回だけ通す小箱。executeBridge は経路が多く(reuse/adopt/launch ×
/// inapp/xcuitest × 実機)、どれかで撃ち漏らすとロックが解放されないままになる
actor ClaimOnce {
    private var fired = false
    private let barrier: PortClaimBarrier

    init(barrier: PortClaimBarrier) { self.barrier = barrier }

    func fire() async {
        guard !fired else { return }
        fired = true
        await barrier.claimed()
    }
}
