// ピッカーのホイール(iOS の pickerWheel・Android の NumberPicker)の値の照合と送り方の判定。
// 判定はここ1か所(DSL setPickerValue と MCP ft_set_picker_value が同じドライバ経路を通る)。
// 行の文字と value の文字が違うことがある(日本語の Simulator: value "14時" に adjust が受けるのは "14")ので、
// 数字だけの指定は current の先頭の整数と数値で比べる。部分一致・丸めはしない。

import Foundation

public enum PickerValueMatch {

    public enum Step: String, Sendable, Equatable {
        case forward, backward
    }

    /// 完全一致(見えない文字・空白の揺れを除いて)か、`wanted` が数字だけで `current` の先頭の整数と数値で等しいか
    public static func matches(current: String, wanted: String) -> Bool {
        let c = canonical(current), w = canonical(wanted)
        if !w.isEmpty, c == w { return true }
        guard let wantedNumber = digitsOnly(w), let currentNumber = leadingInteger(c) else { return false }
        return wantedNumber == currentNumber
    }

    /// 先頭の整数(`"14時"` → 14・`"09"` → 9・`"30 minutes"` → 30)。数字で始まらない・桁あふれは nil
    public static func leadingInteger(_ text: String) -> Int? {
        let digits = canonical(text).prefix(while: { $0.isASCII && $0.isNumber })
        return digits.isEmpty ? nil : Int(digits)
    }

    /// adjust(toPickerWheelValue:) に順に渡す候補。`[wanted]` に加え、`wanted` が数字だけで `current` が数字で始まるなら
    /// ①`current` の先頭の数字の桁数までゼロ埋めした数字(分の行は "00"〜"59" の2桁で、"5" では行が見つからない = 実測)
    /// ②`current` の先頭の数字列をその数字に置き換えた形("14時" → "19時")
    public static func iosCandidates(current: String, wanted: String) -> [String] {
        var result = [wanted]
        let c = canonical(current)
        guard let number = digitsOnly(canonical(wanted)) else { return result }
        let lead = c.prefix(while: { $0.isASCII && $0.isNumber })
        guard !lead.isEmpty else { return result }
        let digits = String(number)
        let body = String(repeating: "0", count: max(0, lead.count - digits.count)) + digits
        for candidate in [body, body + String(c.dropFirst(lead.count))] where !result.contains(candidate) {
            result.append(candidate)
        }
        return result
    }

    /// 数値で決まるときだけ。小さい→ forward。数値でない・等しい(照合済み)は nil
    public static func androidDirection(current: String, wanted: String) -> Step? {
        guard let target = digitsOnly(canonical(wanted)), let now = leadingInteger(current), now != target else { return nil }
        return now < target ? .forward : .backward
    }

    private static func canonical(_ s: String) -> String {
        TextNormalization.selector.apply(TextNormalization.text.apply(s))
    }

    /// 数字(ASCII)だけの文字列の数値。桁あふれ・空は nil
    private static func digitsOnly(_ s: String) -> Int? {
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(s)
    }
}
