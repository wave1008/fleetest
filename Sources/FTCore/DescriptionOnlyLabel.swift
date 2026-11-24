// Android の木で、ラベルが contentDescription だけから来た要素に、可視性検証が描かれた文字を求めてよいか(OI-374)。
// DSL の `occlusionFlip`(V9 の足切りの直後)が呼び手。判定はここ1箇所(文言・注記は呼び手が持つ)。

import Foundation

public enum DescriptionOnlyLabel {
    /// 描かれた文字を求めない(= 在ることと幾何だけ見る)条件。**全部**満たすときだけ true:
    /// ① 期待文字列が要素自身のラベルで、ブリッジが `labelSource == "desc"` と申告した(説明だけから来た)
    /// ② UI フレームワークが分かっていて Flutter でない(Flutter は描く文字も説明にだけ入れる。**不明は従来どおり検証する** =
    ///    不明を既定値で埋めない)
    /// ③ 子孫に同じ label を**文字の出どころ(`labelSource != "desc"`)**で持つ要素が無い
    ///    (React Native のボタンは説明 = ラベルと、同じ文字の子の TextView を持つ = 文字は描かれている)
    public static func skipsDrawnTextCheck(element: ElementInfo, expectedText: String,
                                           in elements: [ElementInfo], app: AppUIFramework?) -> Bool {
        guard element.labelSource == "desc", !expectedText.isEmpty, element.label == expectedText,
              let app, app != .flutter else { return false }
        return !LocatorResolver.descendants(of: element, in: elements).contains {
            $0.label == expectedText && $0.labelSource != "desc"
        }
    }
}
