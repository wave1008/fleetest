// AndroidTouchRotation.swift
// Emulator の gRPC タッチ(`sendTouch`)の座標を、表示の座標から端末の自然な向き(パネル)の座標へ回す純粋関数。
// gRPC は表示の回転を知らず、座標を **自然な向きの画素**(`dumpsys window displays` の `init=` の大きさ)で受ける。
// 横向きで表示の座標をそのまま渡すと縦の座標系で撃たれる(実測 2026-11-02: user_rotation=1 で表示(2000,300)を渡すと
// getevent の生値が自然座標 (2000,300) の比率で出た。逆変換した点を渡すと表示の狙った行に当たった。回転 1・2・3 とも)。
// `adb shell input` は表示の座標を取るのでこの変換は要らない。変換の入口は AndroidDriver.drag / press の gRPC 経路の1箇所。

import Foundation

public enum AndroidTouchRotation {

    public struct Size: Equatable, Sendable {
        public let width: Int32
        public let height: Int32
        public init(width: Int32, height: Int32) {
            self.width = width
            self.height = height
        }
    }

    /// `rotation` は Surface.ROTATION_*(0...3)、`natural` は自然な向きの画面の大きさ(回転前)。
    /// 範囲外の回転は nil(呼び手は gRPC を撃たず adb へ倒す = 表示の座標のまま正しい)
    public static func nativePoint(x: Int32, y: Int32, rotation: Int, natural: Size) -> (x: Int32, y: Int32)? {
        let width = natural.width
        let height = natural.height
        switch rotation {
        case 0: return (x, y)
        case 1: return (width - 1 - y, x)
        case 2: return (width - 1 - x, height - 1 - y)
        case 3: return (y, height - 1 - x)
        default: return nil
        }
    }
}
