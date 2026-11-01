// スクロール探索の「動いたか」の比較で、払いの直後に読んだ木が端のバウンスの途中かもしれない形を見分ける(純粋関数)。
//
// 全部が収まる一覧(動かせない)を払うと、枠が少しずれて戻る(Flutter の ClampingScrollPhysics でない iOS の既定など)。
// 払いの直後の1枚はずれた最中を読むので署名が変わり、「動いた」と数えて端を検知できず、maxSwipes まで回った末に
// 「まだ動いていた」と失敗し、動いたことを根拠に逆走査(ゆっくりしたドラッグ 8 本)まで撃っていた。
// **要素の顔ぶれ(型・id・ラベル・値)が同じで枠だけが違う**ときは、木の署名だけでは「本当にずれた」と「戻る途中」を
// 分けられないので、呼び手は整定を待ってから比べ直す(整定後も違えば本物の移動)。

import Foundation

public enum ScrollSearchBounce {
    /// 枠を除いた署名(順序つき)。`StepExecutor.contentSignature` から枠だけを外したもの
    static func identitySignature(_ elements: [ElementInfo]) -> String {
        var text = ""
        text.reserveCapacity(elements.count * 32)
        for element in elements {
            text += "\(element.type)|\(element.identifier ?? "")|\(element.label ?? "")"
            text += "|\(element.value ?? "")|\(element.enabled)|\(element.checked ?? false);"
        }
        return text
    }

    /// `before` と `after` が「同じ顔ぶれの要素が枠だけ違う」か(= バウンスの途中かもしれない)。
    /// 空の木・顔ぶれが違う木(行が出入りした = 本物のスクロール)は false。
    /// 枠も同じなら false(違いが無いので比べ直す理由が無い)
    public static func sameElementsOnlyDisplaced(_ before: [ElementInfo], _ after: [ElementInfo]) -> Bool {
        guard !before.isEmpty, before.count == after.count else { return false }
        guard identitySignature(before) == identitySignature(after) else { return false }
        return zip(before, after).contains { $0.frame != $1.frame }
    }
}
