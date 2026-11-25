// type の事後の照合の**唯一の入口**(純粋)。「打つ前の値を取る → 打つ → 打った後の木 → 判定」を1つの型で持ち、
// DSL(StepExecutor のロケータ有り・無し)・MCP の ft_type は**ここを通して結果を文言へ写すだけ**にする
// (ft_batch の type は DSL の経路)。呼び手ごとに priorValue の渡し方が違うと、同じ画面で経路ごとに判定が割れる
// (ref なしは前の値を渡さず、伏せ字の数が本文より多い欄への非 ASCII の追記が ok になっていた)。
// 経路の表は `TypedInputCheckRoutesTests` が固定する。ホスト専用。

import Foundation

public enum TypedInputCheck {
    /// 打つ前に控えるもの。`valueBefore` は**打つ瞬間の欄の値**(replace は消した後なので空)
    public struct Prior {
        public let target: ElementInfo?
        public let valueBefore: String
        public let treeBefore: [ElementInfo]
        /// 打つ前(**タップの前**の木)に欄が焦点を持っていたか。ref なしは直前のステップが同じ欄への type だったと言えるときだけ true(`init(focusedIn:previouslyTyped:)`)。焦点を保ったままの打鍵は追記・取り戻した欄は置き換えなので、
        /// 伏せ字の数の期待が変わる(`maskedShortfall` の doc)
        public let wasFocused: Bool

        /// ロケータ有り / ref あり: 対象と、解決した木から引いた値
        public init(target: ElementInfo, priorValue: String, replace: Bool, treeBefore: [ElementInfo]) {
            self.target = target
            self.valueBefore = replace ? "" : priorValue
            self.treeBefore = treeBefore
            self.wasFocused = (TypeReadback.match(of: target, in: treeBefore) ?? target).focused == true
        }

        /// ref なし / ロケータ無し: **打つ直前に読んだ木**の焦点の欄(ちょうど1つのときだけ)を前の値とする。
        /// 直前に読むので replace の消去は既に反映済み。`tree` が nil(読めなかった)・焦点が0/複数 = 前の値は不明(空)
        /// `previouslyTyped` = 直前のステップが type で叩いた欄(間に画面へ触る操作が無いとホストが言えるときだけ渡す)。
        /// 今の木で焦点がちょうど1つで、それが `previouslyTyped` と同じ欄(または包みの中の入力欄)のときだけ焦点を保った扱い。
        /// アプリが焦点を別の欄へ移していれば同じ欄と言えず false のまま
        public init(focusedIn tree: [ElementInfo]?, previouslyTyped: ElementInfo? = nil) {
            let focused = (tree ?? []).filter { $0.focused == true }
            self.target = nil
            self.valueBefore = focused.count == 1 ? TypeReadback.normalizedValue(of: focused[0]) : ""
            self.treeBefore = tree ?? []
            // 木だけでは「焦点を保った」か「タップで取り戻した」かを区別できない(どちらも焦点あり)ので、直前の type の記録がある形だけ true
            self.wasFocused = focused.count == 1 && previouslyTyped.map { TypedInputCheck.isSameField($0, focused[0], in: tree ?? []) } == true
        }
    }

    /// 同じ欄か。木の中の照合(`TypeReadback.match`)の ref が焦点の要素と一致、または対象が包みなら中の入力欄が一致
    static func isSameField(_ typed: ElementInfo, _ focused: ElementInfo, in tree: [ElementInfo]) -> Bool {
        guard let live = TypeReadback.match(of: typed, in: tree) else { return false }
        if live.ref == focused.ref { return true }
        return TypeReadback.enclosedInput(of: live, in: tree)?.ref == focused.ref
    }

    /// ref なしで打つ前に木を読む必要があるか。ref なしの門(`wantsMaskedCheck(target: nil)`)が開くのは
    /// iOS で非 ASCII のときだけで、前の値が要るのもその形だけ(ASCII のみ・Android は前の数を使わない)
    public static func needsPriorRead(text: String, isAndroid: Bool) -> Bool {
        TypedInputVerdict.wantsMaskedCheck(target: nil, text: text, isAndroid: isAndroid)
    }

    /// 打った後の木を読む必要があるか(読まずに済む形は読まない = 往復を増やさない)
    public static func needsAfterRead(prior: Prior, text: String, isAndroid: Bool) -> Bool {
        TypedInputVerdict.wantsMaskedCheck(target: prior.target, text: text, isAndroid: isAndroid)
            || wantsNewlineCheck(target: prior.target, text: text)
    }

    static func wantsNewlineCheck(target: ElementInfo?, text: String) -> Bool {
        text.contains("\n") && !text.hasSuffix("\n") && target.map(TypeReadback.isTextInput) == true
    }

    /// 判定。nil = 通す(値は文言に含めない)
    public static func failure(prior: Prior, text: String, isAndroid: Bool, after: [ElementInfo]) -> String? {
        if wantsNewlineCheck(target: prior.target, text: text), let target = prior.target,
           let message = TypedInputVerdict.newlineMisdelivery(
               target: target, before: prior.treeBefore, after: after, valueBefore: prior.valueBefore, text: text) {
            return message
        }
        guard TypedInputVerdict.wantsMaskedCheck(target: prior.target, text: text, isAndroid: isAndroid),
              let field = TypedInputVerdict.maskedField(target: prior.target, in: after) else { return nil }
        return TypedInputVerdict.maskedShortfall(
            priorValue: prior.valueBefore, priorFocused: prior.wasFocused,
            afterValue: TypeReadback.normalizedValue(of: field), text: text)
    }
}
