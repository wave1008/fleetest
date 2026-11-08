import Foundation

/// clearInput の事後検証が「消え残り」と読んだ値が、欄の絵に本当に描かれているかの判定(純粋関数)。
/// value が入力を映さない欄(M3 SearchBar の iOS は固定の案内文を value に出す)では、空になった欄の value も
/// 消す前と同じで、木だけでは消え残りと区別できない。OCR は呼び手が撮る(`StepExecutor+ClearResidual`)。
/// type の `typedTextIsOnScreen`(打った文字が描かれているか)の対
public enum ClearResidualDrawn {
    public enum Verdict: Equatable, Sendable {
        /// 残りの文字が欄に描かれている = 本物の消え残り
        case drawn
        /// 描かれていない = value だけが残っている
        case notDrawn
    }

    /// - Parameters:
    ///   - ocrLines: 欄の領域から OCR が読んだ行
    ///   - treeTexts: 木が「欄の中に描かれている」と言う文字(`treeTexts(field:in:)`)。一致する行は欄の値ではない
    public static func judge(residual: String, ocrLines: [String], treeTexts: [String]) -> Verdict {
        let known = Set(treeTexts.map(squeeze).filter { !$0.isEmpty })
        let remaining = ocrLines.filter { line in
            let s = squeeze(line)
            return !s.isEmpty && !known.contains(s)
        }
        if RegionText.readable(expected: residual, lines: remaining) { return .drawn }
        // 長い値が欄の幅で切れて一部だけ描かれている本物の消え残りを赤のまま残す
        let whole = squeeze(residual)
        if remaining.contains(where: { whole.contains(squeeze($0)) }) { return .drawn }
        return .notDrawn
    }

    /// 欄自身のラベル(", " で分けた各部分と全体)・placeholder・欄の枠の中にある staticText のラベル
    public static func treeTexts(field: ElementInfo, in elements: [ElementInfo]) -> [String] {
        var texts: [String] = []
        if let label = field.label {
            texts.append(label)
            texts.append(contentsOf: label.components(separatedBy: ", "))
        }
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
