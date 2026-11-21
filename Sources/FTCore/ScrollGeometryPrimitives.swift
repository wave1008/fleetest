// ScrollGeometryPrimitives.swift
// 幾何の判定の部品(実行機 StepExecutor に依存しない。判定の型 ContainerGeometry・EdgeProbe・ScrollFrameResolution と
// 実行機の両方がここを呼ぶ = 依存は実行機 → 判定の一方向)。
// **FTRect 本体(BridgeDTO.swift)には足さない** —— 両 iOS ブリッジの入力なので、足すとブリッジの指紋と版が動く

import Foundation

extension FTRect {
    /// 点が矩形に入るか。**端ちょうどは含む**(閉区間。in-app ブリッジの画面内判定と同じ)。
    /// 半開区間の画面内判定(`TapTargetGeometry.isPointOnScreen`)と取り違えない
    public func containsClosed(x px: Double, y py: Double) -> Bool {
        px >= x && px <= x + width && py >= y && py <= y + height
    }
}

/// スクロール容器が申告する向きつきの操作(`scrollActions` の up/down/left/right)の軸の判定
public enum ScrollActionsAxis {
    /// 払う軸(vertical = up/down・横 = left/right)の向きを1つでも申告しているか
    public static func declares(_ actions: [String]?, vertical: Bool) -> Bool {
        let onAxis: Set<String> = vertical ? ["up", "down"] : ["left", "right"]
        return actions?.contains(where: onAxis.contains) ?? false
    }

    /// 向きつきの申告(up/down/left/right)が、払う軸と違う側だけにあるか
    public static func declaresOnlyOtherAxis(_ actions: [String]?, vertical: Bool) -> Bool {
        guard let actions else { return false }
        return !declares(actions, vertical: vertical) && declares(actions, vertical: !vertical)
    }
}
