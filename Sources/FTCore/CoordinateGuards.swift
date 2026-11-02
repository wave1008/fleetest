import Foundation

/// 座標で撃つ手の判定(MCP の ft_tap / ft_drag / ft_batch の座標の手・CLI の `tap` / `press`・ライブ操作の drag が共有する。
/// 文言は呼び手ごとに持つ = 判定だけを1箇所に置く)。
public enum CoordinateGuards {

    /// 座標がソフトキーボードの矩形の中なら、その矩形(撃つとキーを押す)。木が無い・キーボードが出ていない・画面の外へ隠れたキーボードは nil。
    /// 判定は ref 形・DSL と同じ `KeyboardOcclusion`。**撃つ前の木で見る**
    public static func keyboardFrame(containing x: Double, _ y: Double, in snapshot: SnapshotResponse?) -> FTRect? {
        guard let snapshot else { return nil }
        let occlusion = KeyboardOcclusion.resolve(
            reported: snapshot.keyboardFrame, in: snapshot.elements, screen: snapshot.screen)
        guard let frame = occlusion.frame,
              x >= frame.x, x < frame.x + frame.width, y >= frame.y, y < frame.y + frame.height
        else { return nil }
        return frame
    }

    /// 始点と終点が同じドラッグ(動かない = 押しただけ = 実際にはタップになる)
    public static func dragDoesNotMove(fromX: Double, fromY: Double, toX: Double, toY: Double) -> Bool {
        fromX == toX && fromY == toY
    }
}
