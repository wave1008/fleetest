// type / clearInput の事後の照合の判定(純粋)。DSL(StepExecutor)・MCP(ft_type / ft_clear_input)・ft_batch が共有する。
// 文言は呼び手ごとに持つが、判定(どの欄を secure と見るか・数が足りないか・別の欄が変わったか)はここだけ。
// ホスト専用(TypeReadback.swift はブリッジの入力なので、ホストだけの判定はこのファイルに置く)。

import Foundation

public enum TypedInputVerdict {
    private static let maskCharacters: Set<Character> = ["•", "●", "*"]

    public static func looksMasked(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { maskCharacters.contains($0) }
    }

    /// 打った後に secure 欄の文字数を照合する必要があるか。
    /// 撃つ前の要素が secure なら常に。そうでなくても **iOS で非 ASCII を打つときは見る**: Flutter の secure 欄は
    /// 焦点が入るまで textField と名乗る・id が外側の other に付くので、撃つ前の型では門にならない。
    /// secure 欄が捨てるのは非 ASCII(Android は SET_TEXT で全部入る)なので、ASCII だけの本文は撃つ前の型が secure のときだけ。
    /// 本文が空・改行を含むときは見ない(改行は送信が走りうる)
    public static func wantsMaskedCheck(target: ElementInfo?, text: String, isAndroid: Bool) -> Bool {
        guard !text.isEmpty, !text.contains("\n") else { return false }
        if let target, TypeReadback.isMaskedInput(target) { return true }
        return !isAndroid && !text.allSatisfy(\.isASCII)
    }

    /// 打った後の木で、本文を受けた secure 欄。
    /// target あり: 同じ欄が secure ならそれ。普通の入力欄なら nil。**入力欄でない(id が外側の other に付く Flutter)なら、その枠の中で焦点を持つ
    /// secure 欄**を1つだけ引く。target なし: 焦点を持つ要素が secure ならそれ
    public static func maskedField(target: ElementInfo?, in elements: [ElementInfo]) -> ElementInfo? {
        guard let target else {
            let focused = elements.filter { $0.focused == true }
            return focused.count == 1 && TypeReadback.isMaskedInput(focused[0]) ? focused[0] : nil
        }
        if let match = TypeReadback.match(of: target, in: elements) {
            if TypeReadback.isMaskedInput(match) { return match }
            if TypeReadback.isTextInput(match) { return nil }
        }
        let inside = elements.filter {
            TypeReadback.isMaskedInput($0) && $0.focused == true && target.frame.contains($0.frame)
        }
        return inside.count == 1 ? inside[0] : nil
    }

    /// 伏せ字の数の照合。nil = 通す(値は文言に含めない)。
    /// `priorValue` = **打つ前の欄の値**(分かるときだけ。伏せ字の数だけを使う)。
    /// - 欄が空のまま: 本文に非 ASCII を含むとき赤(ASCII だけなら読めない値として通す)
    /// - 全部伏せ字で数が足りない: 本文の文字数に届かなければ赤(焦点を取り戻した欄は置き換わるので前の数は足さない)
    /// - **打つ前に伏せ字があり本文に非 ASCII を含む**: 置き換わったなら数は本文の長さちょうど・追記なら前 + 本文以上。
    ///   どちらでもなければ(前の数のまま・一部だけ増えた)非 ASCII が落ちている。前の数と本文の長さが偶然同じで
    ///   動いていない形は区別できないので通す。**打つ前に焦点が有った(`priorFocused`)なら追記しか起きない**ので
    ///   置き換えの数(本文の長さちょうど)は通さない(前 + 本文の ASCII だけが入った数と一致しうる = 誤った緑)
    /// - **本文の長さは UTF-16 の単位**(iOS の伏せ字は UTF-16 の単位ごとに1つ。`String.count` だと絵文字が 1 になり誤った赤)
    public static func maskedShortfall(priorValue: String?, priorFocused: Bool, afterValue value: String, text: String) -> String? {
        guard !text.isEmpty, !text.contains("\n") else { return nil }
        let full = text.utf16.count
        let prior = priorValue.map { looksMasked($0) ? $0.count : 0 } ?? 0
        if value.isEmpty {
            guard !text.allSatisfy(\.isASCII) else { return nil }
        } else {
            guard looksMasked(value) else { return nil }
            if prior > 0, !text.allSatisfy(\.isASCII) {
                let replacedWhole = !priorFocused && value.count == full
                guard !replacedWhole, value.count < prior + full else { return nil }
                return "type reported success but the masked field holds \(value.count) character(s) after \(full) were typed"
                    + " into a field that held \(prior) — the field did not accept some of the typed characters"
                    + " (a secure field may reject characters such as non-ASCII text)"
            }
            guard value.count < full else { return nil }
        }
        return "type reported success but the masked field holds \(value.count) character(s) instead of at least"
            + " \(full) — the field did not accept some of the typed characters"
            + " (a secure field may reject characters such as non-ASCII text)"
    }

    /// 改行を含む本文の**宛先の照合**(ランナーは改行入りを一括で打って読み返さないので、焦点が別の欄に残ったままだと
    /// 文字がそちらへ入って ok になる)。**対象の欄が撃つ前のまま・かつ別の入力欄の値が変わったときだけ**赤
    /// (ランナーの 422 と同じ判定 = `TypeReadback.otherInputThatChanged`)。改行で終わる本文は送信が走って欄が空になりうるので見ない。
    /// nil = 通す
    public static func newlineMisdelivery(target: ElementInfo, before: [ElementInfo], after: [ElementInfo],
                                          valueBefore: String, text: String) -> String? {
        guard text.contains("\n"), !text.hasSuffix("\n"), TypeReadback.isTextInput(target),
              let now = TypeReadback.match(of: target, in: after),
              TypeReadback.normalizedValue(of: now) == valueBefore,
              let other = TypeReadback.otherInputThatChanged(target, before: before, after: after) else { return nil }
        return "the text did not go into the field — another input field (\(describe(other))) changed instead, so the tap"
            + " meant to focus the field most likely landed on that one"
    }

    /// 消した後に、**対象以外の入力欄が空になったか**(焦点の別の欄まで消した形 = 無関係な入力の黙った消失)。
    /// 撃つ前に値のあった欄が空になったときだけ。突き合わせは `otherInputThatChanged` と同じ規則
    public static func otherInputCleared(target: ElementInfo, before: [ElementInfo], after: [ElementInfo]) -> ElementInfo? {
        guard let other = TypeReadback.otherInputThatChanged(target, before: before, after: after),
              TypeReadback.normalizedValue(of: other).isEmpty else { return nil }
        // 撃つ前に値があったか(otherInputThatChanged は「変わった」までしか言わない)
        let was = before.filter { candidate in
            if let id = other.identifier, !id.isEmpty { return candidate.identifier == id }
            return (candidate.identifier ?? "").isEmpty && candidate.type == other.type && candidate.frame == other.frame
        }
        guard was.count == 1, !TypeReadback.normalizedValue(of: was[0]).isEmpty else { return nil }
        return other
    }

    public static func clearedOtherInputMessage(_ other: ElementInfo) -> String {
        "the field was cleared, but another input field (\(describe(other))) was emptied too — the tap meant to focus the"
            + " target most likely did not move input focus, so the focused field was cleared as well"
    }

    public static func describe(_ element: ElementInfo) -> String {
        element.identifier.map { "#\($0)" } ?? element.label.map { "\"\($0)\"" } ?? element.type
    }
}
