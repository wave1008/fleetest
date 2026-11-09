// 文字列を比較する前の正規化。**用途で規則が違う**ので1つの enum に閉じ込める。
//
// 用途は2つあり、求められるものが逆を向いている(ユーザー決定):
//
//   セレクタでフィルタする … **見つけたい**。書き手が打った式と実データの些細な差で
//                             空振りしないよう、寛容に寄せる(両端トリム・空白の種類を吸収)
//   テキストを期待値と比較 … **確かめたい**。「見た目が完全に一致していれば同じ」が基準なので、
//                             見えない差だけを吸収し、**見える差は残す**(半角と全角は別物)
//
// **クラスタ内の制御文字は消さない**のが両者共通の要。ZWJ / 異体字セレクタ / 結合文字は
// 「不可視の制御文字」であると同時に**書記素クラスタを形成する**ので、落とすと
// 👨‍👩‍👦(1クラスタ)が 👨👩👦(3クラスタ)と等しくなり、❤️ が ❤ になる = 見た目が変わる。
// 実測でこの分類を確定させた(`"A" + 対象 + "B"` のクラスタ数):
//   クラスタ内(残す)… ZWNJ U+200C / ZWJ U+200D / CGJ U+034F / VS15,16 U+FE0E,FE0F / 結合文字
//   単独  (消す)… ZWSP U+200B / BOM U+FEFF / WJ U+2060 / SOFT HYPHEN U+00AD /
//                    LRM,RLM,LRE,PDF,LRI / ALM U+061C / MVS U+180E / C0,C1
//
// **列挙で持たない**: 判定は「そのクラスタが `Cf`(書式)と `Cc`(制御)だけで出来ているか」。
// 単独で立つ不可視文字はクラスタ全体が不可視になるので落ち、クラスタ内の制御文字は
// 可視の文字と同じクラスタに居るので残る。数え漏らした文字にも自動で効く。

import Foundation

/// 比較前の正規化規則。**どちらで比較したか**は失敗メッセージにも出す(読み手の次の一手が変わる)
public enum TextNormalization: String, Sendable, CaseIterable {

    /// セレクタのフィルタ用。両端をトリムし、空白は種類を問わず U+0020 へ寄せて連続を畳む
    case selector

    /// テキストと期待値の比較用(既定)。**見た目が同じものだけ**同一視する ——
    /// 不可視文字は落とすが、幅の違う空白(全角・thin space 等)は別物のまま
    case text

    /// 厳密比較。**一切正規化しない**。`strict: true` を明示したときだけ使う
    case strict

    /// 空白として U+0020 へ寄せる文字。**`text` では NBSP だけ** —— NBSP は半角空白と
    /// 同じ幅・同じ見た目で、違うのは改行の可否だけだから。全角(U+3000)や thin space
    /// (U+2009)・narrow NBSP(U+202F)は**幅が違う = 見た目が違う**ので寄せない。
    /// `selector` は「見つける」側なので空白の種類を問わず寄せる
    func foldsToSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch self {
        case .strict:
            return false
        case .text:
            return scalar == "\u{00A0}"
        case .selector:
            // **列挙しない**: Unicode の White_Space 性質そのものを使う。タブ・改行・
            // 垂直タブ・改頁・NEL(U+0085)・全角・NBSP・U+2028/2029 が一度に入る。
            // ゼロ幅(U+200B 等)は White_Space ではないので、ここではなく削除規則の側で落ちる
            return scalar.properties.isWhitespace
        }
    }

    /// 結合子(ZWJ / ZWNJ)。**後ろに繋ぐ相手が居るときだけ意味を持つ**ので、クラスタの末尾に
    /// 余っているものは落とす。実データの根拠(Google マップの路線ラベル):
    /// `"…中央線\u{200D}\u{FEFF}\u{2060}"` の ZWJ は 線 と1クラスタになるが**繋ぐ相手が無く**、
    /// 見た目は `"中央線"` そのもの。残すと目視で同一の文字列が完全一致に失敗する。
    /// 一方 `"👨\u{200D}👩"` の ZWJ は2つの絵文字を繋いでおり、落とすと見た目が変わる。
    /// **異体字セレクタ(VS15/16)は末尾でも落とさない** —— あれは直前の文字の見え方を変えるので、
    /// 繋ぐ相手が要らない(❤ と ❤️ は別の見た目)
    private static let danglingJoiners: Set<Unicode.Scalar> = ["\u{200C}", "\u{200D}"]

    /// **「空」の唯一の定義**(セレクタ・画面の文字・期待値で共有)。2段: ①ユーザーに見えない文字を除外する(`text` の規則 =
    /// 単独で立つ書式文字 `Cf` と制御文字 `Cc`。絵文字の ZWJ・異体字セレクタのように見た目の文字と1文字を作るものは残す)
    /// ②残りが空白だけかを正規表現で見る。41〜44周目に空・`=`・空白・改行と経路を変えて4度、空の値の誤った緑が出た
    /// 単独で立つと見えない文字: 書式文字(`Cf`)・制御文字(`Cc`)と、Unicode の「既定で無視される」文字(異体字セレクタ U+FE0F・
    /// CGJ U+034F 等 = 分類は `Mn` だが見た目を持たない。45周目 im4 F2)。空白(White_Space)は見えるので除く
    static func isInvisibleScalar(_ scalar: Unicode.Scalar) -> Bool {
        guard !scalar.properties.isWhitespace else { return false }
        let category = scalar.properties.generalCategory
        return category == .format || category == .control || scalar.properties.isDefaultIgnorableCodePoint
    }

    /// **正規表現の照合の唯一の定義**: パターンは書き換えず、値の「素のまま」と「この規則で正規化した後」の両方に当て、
    /// 先に一致した方の一致部分を返す(nil = どちらにも一致しない)。`strict` は素のままだけ。
    /// パターンから見えない文字を消すと、空のパターンになる・量指定子が前の文字へ移る・`[]` に化ける(46周目に5人が再現)ので
    /// 書き換えない(ユーザー決定 11/9)。否定形は「どちらにも一致しない」で成立
    public static func regexMatch(_ actual: String, pattern: String, under normalization: TextNormalization) -> String? {
        if let range = actual.range(of: pattern, options: .regularExpression) { return String(actual[range]) }
        guard normalization != .strict else { return nil }
        let normalized = normalization.apply(actual)
        guard let range = normalized.range(of: pattern, options: .regularExpression) else { return nil }
        return String(normalized[range])
    }

    public static func isBlank<S: StringProtocol>(_ value: S) -> Bool {
        TextNormalization.text.apply(String(value)).range(of: blankPattern, options: .regularExpression) != nil
    }

    /// 空白と数える文字の全部(正規表現 1 本に置く = 種類を足すのはここだけ): Unicode の空白(`\p{White_Space}` = 半角・全角・
    /// 改行・タブ等)と区切り(`\p{Z}`)。`\A`〜`\z` で全体を縛る(`$` は末尾の改行の前でも一致する)
    static let blankPattern = #"\A[\p{White_Space}\p{Z}]*\z"#

    public func apply(_ s: String) -> String {
        guard self != .strict else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        for cluster in s {
            // **空白は「不可視」ではない**(桁を食う = 見える)。タブ・改行は分類上 `Cc` なので、
            // 下の削除規則より**先に**寄せる —— 順序を逆にすると `"A\tB"` が `"AB"` になり、
            // 空白の正規化ではなく消去になってしまう(テストで検出)。
            // **`allSatisfy` で複数スカラのクラスタも見る** —— `"\r\n"` は CR+LF の2スカラで
            // 1書記素クラスタになるため、単独スカラだけ見ると素通りして生の `\r\n` が残る
            if cluster.unicodeScalars.allSatisfy(foldsToSpace) {
                out.append(" ")
                continue
            }
            // **クラスタ丸ごと不可視なら落とす**(単独で立つ書式/制御文字)。
            // 可視の文字と同じクラスタに居る制御文字はここを通らないので残る。
            // 空白(White_Space)は上で扱い済み・寄せない modes では**残す**(見た目に効くため)
            if cluster.unicodeScalars.allSatisfy(Self.isInvisibleScalar) {
                continue
            }
            // 末尾に余った結合子だけを落とす(上のコメントの理由)
            var scalars = Array(cluster.unicodeScalars)
            while let last = scalars.last, Self.danglingJoiners.contains(last) {
                scalars.removeLast()
            }
            // 見た目を変えない結合: CGJ は常に・異体字セレクタは絵文字でない文字の後ろだけ落とす(`ム\u{FE0F}` は「ム」と同じ見た目。
            // ❤ と ❤️ は見た目が違うので絵文字の後ろは残す。46周目 duo F2・phys F3)
            if let base = scalars.first {
                scalars = [base] + scalars.dropFirst().filter { scalar in
                    !(scalar == "\u{034F}" || (scalar.properties.isVariationSelector && !base.properties.isEmoji))
                }
            }
            out.unicodeScalars.append(contentsOf: scalars)
        }
        guard self == .selector else { return out }
        // 連続空白は1つに畳み、両端はトリムする(セレクタだけ)
        return out.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
