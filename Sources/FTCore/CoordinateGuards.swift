import Foundation

/// 座標で撃つ手の判定(MCP の ft_tap / ft_drag / ft_batch の座標の手・CLI の `tap --x --y`・ライブ操作の drag が共有する。
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

/// CLI の `--ref` の古さの判定(純粋)。CLI は呼び出しごとに別プロセスで、ブリッジの ref の表は直近の snapshot 1世代だけ
/// (撃つ前の守りが木を撮り直すので、表は常に「今の木」になり、ドライバ・ブリッジの `expect` の照合は必ず一致する)。
/// そこで**利用者が最後に見た木の ref → 目印(identifier・型)**を呼び出しをまたいで控え、撃つ前に今の木と照らす。
/// 照合の規則は `RefExpectationScope.contradicts`(位置・ラベルは見ない = 値の表示やスクロールで誤って断らない)
public enum RefTableMemo {
    public typealias Table = [Int: RefExpectation]

    public static func table(of elements: [ElementInfo]) -> Table {
        Dictionary(elements.map { ($0.ref, RefExpectation($0)) }, uniquingKeysWith: { first, _ in first })
    }

    /// 控えと今の要素が食い違うときの断り文の一次情報(nil = 食い違わない・控えに無い)
    public static func staleDetail(ref: Int, remembered: Table?, now element: ElementInfo) -> String? {
        guard let expected = remembered?[ref] else { return nil }
        let latest = RefExpectation(element)
        guard RefExpectationScope.contradicts(expected, latest: latest) else { return nil }
        return "ref [\(ref)] was \(describe(expected)) in the last snapshot you took, but it is \(describe(latest)) on the screen now"
    }

    private static func describe(_ e: RefExpectation) -> String {
        e.identifier.flatMap { $0.isEmpty ? nil : "\(e.type) #\($0)" } ?? e.type
    }
}
