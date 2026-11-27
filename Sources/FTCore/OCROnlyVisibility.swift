// occlusion-guard: FM が判定を返さなかったとき(macOS 26 で画像を渡せない・実呼び出しの失敗・
// 直列化待ちの期限切れ・陽性対照の注入)の代替判定。使う材料は同じ呼び出しの中で Tier-2 の近道が
// **既に読んだ** OCR の行(lines)と、Tier-1 のインク量だけ —— 追加の OCR は撃たない
// (近道が撃たれていない回は lines = nil = 判定不能。「読んで何も無かった」[] と混ぜると、読んでいない
// のにインク量だけで不可視と言う —— E2E のコンパイル前のステップで実際に出た)。
//
// **不可視なら FM の反転と同じく赤**(警告の段階で E2E とコーパスの誤った赤 0 を確かめてから上げた。
// 実測は OG-5.19)。**FM の反転と同じく、スクショが古い絵のままだと赤になる**
// (モニターの配信が張られた Android Emulator で実際に出た)—— OCR 固有の問題ではない。

import Foundation

public enum OCROnlyVisibility {
    public enum Outcome: Sendable, Equatable {
        case visible(TranscriptMatch.State)
        case notVisible(TranscriptMatch.State)
        /// 読める行が無く、インク量からも判定できない(画像不正 / 何か描かれてはいるが読めない
        /// = WebView・図形等)
        case undetermined
    }

    /// FM が判定を返さない run の occlusion-guard を説明する但し書き(括弧つき・先頭空白つき)。CLI の警告・
    /// FMHealth・doctor・ft_status が共有する。**ocrTextVisibilityCheck を知らない呼び手でも真になる形**
    /// (off なら読みが無く judge は常に判定不能 = 素通り)
    public static let fmFallbackCaveat =
        " (text that OCR cannot judge passes unchecked; with ocrTextVisibilityCheck off the guard passes through)"

    /// FM の判定が無い run の occlusion-guard が何で判定するかの句(「the occlusion-guard … 」の述語)。**OCR が使えない機械では
    /// OCR でも読めない**(macOS 26 = OCRSupport)ので、「OCR だけで判定する」と言わない(M4Max で doctor と食い違った)
    public enum Tense { case present, past, gerund }

    public static func fmFallbackGuardPhrase(ocrSupported: Bool, tense: Tense = .present) -> String {
        let unsupportedTail = " (note visual-text-check-unsupported; only geometry and a blank region fail)"
        switch (ocrSupported, tense) {
        case (true, .present): return "judges from on-device OCR alone" + fmFallbackCaveat
        case (true, .past): return "judged from on-device OCR alone" + fmFallbackCaveat
        case (true, .gerund): return "judging from on-device OCR alone" + fmFallbackCaveat
        case (false, .present):
            return "cannot read the drawn text either (\(OCRSupport.requirement)), so text it cannot read passes unchecked" + unsupportedTail
        case (false, .past):
            return "could not read the drawn text either (\(OCRSupport.requirement)), so text it could not read passed unchecked" + unsupportedTail
        case (false, .gerund):
            return "unable to read the drawn text either (\(OCRSupport.requirement)), so text it could not read passed unchecked" + unsupportedTail
        }
    }

    /// FM の判定と OCR の読みの判定の突き合わせ。**見えていると読めた側を採る**(赤は両方が見えないと
    /// 言った回か、OCR が判定不能で FM が見えないと言った回だけ)。どちらも期待文字列を知らずに読んだ文字を
    /// 同じ `TranscriptMatch` で照合するので「読めた」は描かれている直接の証拠で、「読めなかった」は読み手の
    /// 失敗でも起きる。割れた回は `disagreement` の注記で残す(率で監査する)。根拠は OG-5.22
    public static func merge(fmVisible: Bool, fmState: TranscriptMatch.State?,
                             ocr: Outcome) -> (visible: Bool, state: TranscriptMatch.State?, disagreement: StepNote?) {
        switch ocr {
        case .visible(let state) where !fmVisible:
            return (true, state, .ocrReadWhatFMMissed)
        case .notVisible where fmVisible:
            return (true, fmState, .fmReadWhatOCRMissed)
        default:
            return (fmVisible, fmState, nil)
        }
    }

    /// 文字の子を持たない行(iOS のセル)を見えていないと判定するか(赤 + 注記 `row-label-not-read`)。FM は使わない。
    /// 赤にするのは**読めた文字があるのに `TranscriptMatch` が見えていないと言う**(別の文字・先頭の半分以下)ときだけ =
    /// 省略記号で切った文字・半分より多く見えている文字はテキストの要素と同じく緑。
    /// nil(読んでいない)と空(1行も読めない = ラベルが文字として描かれていない行)は赤にしない
    /// **読めた文字が期待と字形の取り違え(`TranscriptMatch.containsWithConfusableGlyphs`)だけ違う区間を含むなら赤にしない** —— 行は FM で確かめ直さない
    /// (1件 1.5〜2 秒の払いを避ける)ので、OCR の取り違えがそのまま赤になる(E2EY-iOS の反転チャットで描かれた "yo1" を Vision は
    /// 等倍 "01"・×2/×3 "Y01" と読み、上位候補も1つだけ)。隣の行・別の文字は取り違え以外の差を含むので赤のまま
    /// **結合ラベル(`、` か `, ` で子の文字をつないだ行のラベル)は先頭の区切り(行の題名)で確かめる** —— 読み上げ用の文(「、0件のリマインダー」)は
    /// 画面に描かれず、全体を求めると OCR が読み終えた回は決まって赤になった(標準アプリのリマインダーの一覧・Simulator iOS 27.2。描かれるのは
    /// 「Ztestリスト」と件数の「0」だけ)。先頭の区切りも読めなければ(何も読めない・別の文字)従来どおり赤
    public static func rowLabelNotRead(lines: [String]?, expected: String) -> Bool {
        guard let lines, !lines.isEmpty else { return false }
        let transcript = lines.joined(separator: " ")
        for candidate in [expected, mergedLabelHead(expected)].compactMap({ $0 }) {
            if TranscriptMatch.judge(transcript: transcript, expected: candidate).visible { return false }
            if TranscriptMatch.containsWithConfusableGlyphs(transcript: transcript, expected: candidate) { return false }
        }
        return true
    }

    /// 結合ラベルの先頭の区切り(`、` / `, ` の手前)。区切りが無い・先頭が空なら nil。
    /// 読点(U+3001)は照合用で表示ではないので、エスケープで書く(CLIEnglishStringsScanTests。SnapshotRendering と同じ)
    static func mergedLabelHead(_ label: String) -> String? {
        guard let cut = [label.range(of: "\u{3001}"), label.range(of: ", ")].compactMap({ $0 }).min(by: { $0.lowerBound < $1.lowerBound })
        else { return nil }
        let head = label[..<cut.lowerBound].trimmingCharacters(in: .whitespaces)
        return head.isEmpty ? nil : head
    }

    /// `lines` が nil(読んでいない)なら判定不能。空でなければ `TranscriptMatch.judge` へそのまま回す。
    /// 空なら `inkStdDev` で「描かれていない」か「判定不能」かだけを分ける。
    public static func judge(lines: [String]?, expected: String,
                             inkStdDev: Double?, inkThreshold: Double) -> Outcome {
        guard let lines else { return .undetermined }
        if !lines.isEmpty {
            let verdict = TranscriptMatch.judge(transcript: lines.joined(separator: " "), expected: expected)
            return verdict.visible ? .visible(verdict.state) : .notVisible(verdict.state)
        }
        // **occlusionInkThreshold をそのまま流用する**(専用の定数を置かない)。根拠: 実 crop
        // 290 件 + 合成で、この閾値を 6〜20 のどこに置いても結果は同一(空白は 0 付近・文字は
        // 40 以上に分かれ、間に境界例が無い。OG-5.19)
        guard let inkStdDev else { return .undetermined }
        return inkStdDev < inkThreshold ? .notVisible(.notRendered) : .undetermined
    }
}

/// **陽性対照の注入口**。FM の実際の不調(モデル不可用・ブレーカ開)は意図的に起こせないので、
/// これが無いと「FM が答えを返さなかった」経路を一度も通せない。デバイスを触る動作は何もしない
/// (`FrozenInjection` と同じ規律 —— 観測・分岐だけを差し替える)。
public enum FMNoVerdictInjection {
    public static let environmentKey = "FT_FAKE_FM_NO_VERDICT"

    public static func isActive(environment: [String: String]) -> Bool {
        environment[environmentKey] == "1"
    }
}
