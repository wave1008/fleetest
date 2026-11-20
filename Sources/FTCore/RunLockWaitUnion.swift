// RunLockWaitUnion.swift
// ロックの待ち(キューに入ってから渡し・失敗・取り消しまで)の**和集合の時間**。1つの出どころ(リモートへのディスパッチ1回)の
// 要求のうち、少なくとも1つが待っていた時間の壁時計の合計 = その機械がロックで止まっていた時間(デバイス数ぶんの足し算にしない)。
// 中継役が `RemoteTimeout` の期限を延ばす材料(`RunLockServer` が持ち、制御用の接続で答える)。純粋な型(時刻は呼び手が渡す)。

import Foundation

public struct RunLockWaitUnion: Sendable, Equatable {
    // 不変条件: active = いま待っている要求の数・startedMs は active が 0 → 1 になった時刻・completedMs は閉じた区間の合計
    private var active = 0
    private var startedMs = 0
    private var completedMs = 0

    public init() {}

    /// 要求が待ちに入った
    public mutating func begin(nowMs: Int) {
        if active == 0 { startedMs = nowMs }
        active += 1
    }

    /// 要求の待ちが終わった(渡し・失敗・取り消し・接続の終わり)。待っていない状態での呼び出しは無視する
    public mutating func end(nowMs: Int) {
        guard active > 0 else { return }
        active -= 1
        if active == 0 { completedMs += max(0, nowMs - startedMs) }
    }

    /// いま待っている要求が居るか
    public var isActive: Bool { active > 0 }

    /// 閉じた区間の合計 + 進行中なら今までの分(ミリ秒)
    public func totalMs(nowMs: Int) -> Int {
        completedMs + (active > 0 ? max(0, nowMs - startedMs) : 0)
    }
}

/// 中継役の期限(`RemoteTimeout`)の延長の判断(純粋関数)。**ロックの待ちの時間だけ延ばす**
public enum RemoteTimeoutExtension {
    /// 今回さらに延ばすミリ秒。`waitedMs` = サーバーが数えた累計・`extendedMs` = これまでに延ばした合計・`capMs` = 延長の合計の上限。
    /// 上限: 延長の合計は元の期限(`RemoteTimeout.seconds` の値)を超えない(根拠: ロックの待ちは run の壁時計の一部なので、元の見積りの
    /// 全部をロックの待ちに使う run は詰まっている。サーバーが数え続ける詰まりで無限に延びないための安全弁)。
    /// 負の値・上限超えは 0 に丸める
    public static func additionalMs(waitedMs: Int, extendedMs: Int, capMs: Int) -> Int {
        let target = min(max(0, waitedMs), max(0, capMs))
        return max(0, target - max(0, extendedMs))
    }
}
