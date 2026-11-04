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

    /// 入力欄でない対象(id を載せた包み)の中の入力欄。同じ枠の欄(`sameFrameInput`)→ 子孫のちょうど1つ
    /// (`TapTargetGeometry.nonInputTypeTargetNote` と同じ「ちょうど1つ」)。type が包みから欄へ解決する規律と
    /// valueIs 等の値の読みで共有する
    public static func enclosedInput(of target: ElementInfo, in elements: [ElementInfo]) -> ElementInfo? {
        guard !isTextInput(target) else { return nil }
        if let field = sameFrameInput(of: target, in: elements) { return field }
        guard let index = elements.firstIndex(where: { $0.ref == target.ref }) else { return nil }
        var inner: [ElementInfo] = []
        var cursor = elements.index(after: index)
        while cursor < elements.endIndex, elements[cursor].depth > target.depth {
            if isTextInput(elements[cursor]) { inner.append(elements[cursor]) }
            cursor = elements.index(after: cursor)
        }
        return inner.count == 1 ? inner.first : nil
    }

    /// value* の検証が読む値。要素自身が値を持たず、包みの中に唯一の入力欄があるときだけその欄の値
    public static func assertedValue(of element: ElementInfo, in elements: [ElementInfo]) -> String? {
        if element.value != nil { return element.value }
        return enclosedInput(of: element, in: elements)?.value
    }
}
