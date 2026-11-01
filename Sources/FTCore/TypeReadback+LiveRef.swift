// TypeReadback.value(of:in:) が読む要素そのもの(ホスト側だけで使う)。**TypeReadback.swift はブリッジの入力**
// (BridgeSourceSet・ランナーと in-app が共有)なので、ホストだけの関数はこのファイルに置く(触ると版上げが要る)。
// 突き合わせの規則は value(of:in:) と同じでなければならない(TypeReadbackLiveRefTests が等価を固定する)

import Foundation

extension TypeReadback {
    /// 撮り直した木の中の同じ欄(identifier が空でなければ identifier、無ければ frame で1つに決まるときだけ)。
    /// **撮り直した後に撃つ ref はこれの ref**(ブリッジは撮るたびに ref の表を作り直す)
    public static func match(of target: ElementInfo, in elements: [ElementInfo]) -> ElementInfo? {
        let matches = elements.filter { sameField(target, $0) }
        return matches.count == 1 ? matches.first : nil
    }

    /// 入力欄でない対象と同じ枠で重なる入力欄(Flutter は id を外側の other に載せる)。ちょうど1つのときだけ。
    /// `nonInputTypeTargetNote` は内側(深い要素)を見るので同じ深さで並ぶこの形に当たらない
    public static func sameFrameInput(of target: ElementInfo, in elements: [ElementInfo]) -> ElementInfo? {
        let inputs = elements.filter { isTextInput($0) && $0.frame == target.frame }
        return inputs.count == 1 ? inputs.first : nil
    }
}
