import Foundation

/// clearInput の事後検証が「消え残り」と読んだ欄が、絵の上で本当に空かの判定(純粋関数)。
/// value が入力を映さない欄(M3 SearchBar の iOS は固定の案内文を value に出す)では、空になった欄の value も
/// 消す前と同じで、木だけでは消え残りと区別できない。OCR は呼び手が撮る(`StepExecutor+ClearResidual`)。
/// **残った value が描かれているかを見るのではない** —— この種の欄の value は中身ではないので、消し損ねた入力("bx")が
/// 描かれていても value の文字は描かれず、それを「空」の証拠にすると誤った緑になる。見るのは「木が言う飾りの文字の他に、
/// 欄の中に1行でも読めたか」で、読めたら(何であれ)消え残り = 赤のまま
public enum ClearResidualDrawn {
    public enum Verdict: Equatable, Sendable {
        /// 飾りの文字の他に何か描かれている = 消え残りの疑い(赤のまま)
        case drawn
        /// 飾りの文字の他に何も読めない = 絵の上では空
        case notDrawn
    }

    /// - Parameters:
    ///   - ocrLines: 欄の領域から OCR が読んだ行
    ///   - treeTexts: 木が「欄の中に描かれている飾り」と言う文字(`treeTexts(field:in:)`)。一致する行は中身ではない
    /// 1行も読めない細い・短い消え残りは見逃す(OCR の限界。読み手の故障は呼び手が `readerIsAlive` で分ける)
    public static func judge(ocrLines: [String], treeTexts: [String]) -> Verdict {
        remainingLines(ocrLines: ocrLines, treeTexts: treeTexts).isEmpty ? .notDrawn : .drawn
    }

    /// 飾りの文字を除いて残った行(赤の失敗文に事実として添える)
    public static func remainingLines(ocrLines: [String], treeTexts: [String]) -> [String] {
        let known = Set(treeTexts.map(squeeze).filter { !$0.isEmpty })
        return ocrLines.filter { line in
            let s = squeeze(line)
            return !s.isEmpty && !known.contains(s)
        }
    }

    /// placeholder・欄の枠の中にある staticText のラベル。**欄自身のラベルは入れない** —— 入力を
    /// ラベルへ畳む構成("bx, Search")では、消し損ねた入力そのものを飾りとして除いてしまう
    public static func treeTexts(field: ElementInfo, in elements: [ElementInfo]) -> [String] {
        var texts: [String] = []
        if let placeholder = field.placeholder { texts.append(placeholder) }
        for e in elements where e.ref != field.ref && e.type == "staticText" && field.frame.contains(e.frame) {
            if let label = e.label { texts.append(label) }
        }
        return texts
    }

    /// 欄の絵を OCR に頼めない理由(nil = 頼める)。伏せ字・画面に収まらない・キーボードと重なる欄は絵が欄の全体を映さない
    public static func unreadableReason(field: ElementInfo, screen: FTRect, keyboard: FTRect?) -> String? {
        if TypeReadback.isMaskedInput(field) { return "the field is masked" }
        let f = field.frame
        // 全体が収まるかを見る(`FTRect.contains` は中心点の判定で意味が違う)
        guard f.width > 0, f.height > 0,
              f.x >= screen.x, f.y >= screen.y,
              f.x + f.width <= screen.x + screen.width, f.y + f.height <= screen.y + screen.height else {
            return "the field is not fully on the screen"
        }
        if let k = keyboard, k.width > 0, k.height > 0,
           f.x < k.x + k.width, k.x < f.x + f.width, f.y < k.y + k.height, k.y < f.y + f.height {
            return "the keyboard overlaps the field"
        }
        return nil
    }

    private static func squeeze(_ s: String) -> String { s.filter { !$0.isWhitespace } }
}
