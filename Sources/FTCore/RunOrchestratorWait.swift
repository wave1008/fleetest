// RunOrchestratorWait.swift
// RunOrchestrator の待ちの部品: 中断で抜けられる待ち(`awaitUnlessInterrupted`)と、親の開始の行の待ち(`awaitStartGate`。RR-8.4)。

import Foundation

/// `work` の結果を待つ。**ただし中断が先に来たら待たずに `fallback` を返す**(`work` は背後で最後まで
/// 走る = 取り消す口の無い仕事でも呼び手は抜けられる)。`work` が先に終われば待ち手を片付けてから返す
func awaitUnlessInterrupted<T: Sendable>(
    _ work: @escaping @Sendable () async -> T, interrupted flag: RunInterruptFlag, fallback: T
) async -> T {
    await withCheckedContinuation { continuation in
        let first = FirstResumer(continuation)
        Task {
            let value = await work()
            await flag.stopWaiting()
            first.resume(value)
        }
        Task {
            if await flag.waitUntilRequested() { first.resume(fallback) }
        }
    }
}

/// 2つの async のうち先に終わったほうの値(一度だけ resume する)
private final class FirstResumer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }
    func resume(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

extension RunOrchestrator {
    /// 親とつながった子が、**最初のワーカーを走らせる直前**(供給とビルドが済んだ後。供給は並行で進む)に親の開始の行を待つ。
    /// nil = 待たない。待っている間も中断で解ける(解けたら `.start` 扱い = 以後の配布は中断が止める)。
    /// 取りやめなら1本も流さない: 理由を `RunSummary.abortReason`(`lateJoinAbort`)と `RunSummary.startCancelled` に残し(**取りやめが中断に勝ったときだけ**。中断で抜けた後に背後の待ちが取りやめを受けても残さない)、配布を止める。
    /// 実行していないシナリオは赤として記録せず(`startCancelled`)、afterAll も撃たない(何も始まっていない)
    func awaitStartGate(_ startGate: (@Sendable () async -> WorkQueueProtocol.StartSignal)?) async {
        guard let startGate else { return }
        let signal = await awaitUnlessInterrupted(startGate, interrupted: interruptRequested, fallback: .start)
        guard case .cancel(let reason) = signal else { return }
        startCancelled.value = reason
        lateJoinAbort.value = reason
        requestInterrupt()
        await interruptRequested.request()
    }
}
