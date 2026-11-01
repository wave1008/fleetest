// 木の行に付ける「画面に描かれていない」印の判定。MCP の ft_snapshot と CLI の snapshot が共有する
// (判定は1箇所・文言は呼び手ごと。片方だけにあると同じ要素に一方だけ印が出る)。

import Foundation

public enum SnapshotGhostFlags {
    /// 撃つと別の物に当たる(容器の外の残像・同一矩形への積み重なり)。**印を2種類に割らない**(打ち手が同じ)
    public static let leftoverMark = "⚠️scroll-leftover"
    /// 単に画面の外に居る行。leftover と**危険度が違う**(leftover は沈黙した誤操作・offscreen は「今そこに無い」だけ)ので割る
    public static let offscreenMark = "⚠️offscreen"

    /// 容器の外の残像。申告されたスクロール容器の外も同じ印に混ぜる(`isUntappableGhost` の入口は容器の推測なので、
    /// 申告のある UIKit/SwiftUI の木では1件も付かない)
    public static func ghostRefs(_ snapshot: SnapshotResponse) -> [Int] {
        snapshot.elements
            .filter {
                OcclusionGeometry.isUntappableGhost($0, in: snapshot.elements, screen: snapshot.screen)
                    || TapTargetGeometry.outsideDeclaredScroller(
                        $0, in: snapshot.elements, screen: snapshot.screen) != nil
            }
            .map(\.ref)
    }

    /// ref → 印。画面外判定は DSL と共有(`TapTargetGeometry.offscreenAdvisory`)
    public static func flags(_ snapshot: SnapshotResponse) -> [Int: String] {
        let refs = Set(ghostRefs(snapshot)).union(OcclusionGeometry.stackedRefs(snapshot.elements))
        var flags: [Int: String] = [:]
        for element in snapshot.elements where refs.contains(element.ref) {
            flags[element.ref] = TapTargetGeometry.offscreenAdvisory(
                for: element, screen: snapshot.screen) != nil ? offscreenMark : leftoverMark
        }
        return flags
    }
}
