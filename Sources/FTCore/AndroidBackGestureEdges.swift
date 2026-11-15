// AndroidBackGestureEdges.swift
// `adb shell dumpsys activity service com.android.systemui/.SystemUIService` の出力から、
// ジェスチャナビゲーションが back として奪う左右の帯幅(px)を読む純粋パーサ。
// 座標ドラッグ(swipeBy / swipePointToPoint / swipeElementToElement)の始点・終点をこの帯の外へ逃がすために
// ScrollGeometry.panPath と StepExecutor.clearingBottomGestureBand が使う
// (帯の内側に始点/終点を置くと、そのドラッグが back として消費され画面がアプリから離脱する)。

import Foundation

public enum AndroidBackGestureEdges {

    /// - Returns: ジェスチャナビが有効(`mIsGestureHandlingEnabled` か、Android 12・13 の実機が出す `mIsGesturalModeEnabled`)のときだけ `(mEdgeWidthLeft, mEdgeWidthRight, 下端の帯の高さ)`。
    ///   下端は `mBottomGestureHeight` が読めればその値、読めなければ `bottomFallback`(OS の版で
    ///   ダンプに出ない。呼び手が dp 上限 × 密度で渡す。根拠は `AndroidDriver.backGestureEdgeWidths`)。
    ///   左右は mEdgeWidth に mLeftInset / mRightInset(横向きの切り欠き)を足した実幅。
    ///   `false`(3ボタン navigation)は除外不要なので `(0, 0, 0)`。ブロックが無い/値が読めないときは
    ///   nil(呼び手は除外しない側に倒す)。**`EdgeBackGestureHandler:` ブロックはダンプ中に複数回
    ///   現れうるが、値は同一なので最初の1つを採る**
    public static func parse(_ dumpsys: String, bottomFallback: Double = 0) -> (left: Double, right: Double, bottom: Double)? {
        guard let block = block(named: "EdgeBackGestureHandler:", in: dumpsys) else { return nil }
        guard let enabled = gestureEnabled(in: block) else { return nil }
        guard enabled else { return (0, 0, 0) }
        guard let left = doubleValue(named: "mEdgeWidthLeft", in: block),
              let right = doubleValue(named: "mEdgeWidthRight", in: block) else { return nil }
        // 帯は画面の物理端ではなく切り欠き(cutout)・システムバーの内側から数える: 実幅 = inset + 幅。横向きの Pixel 4a は
        // mLeftInset=136 で、82 だけ避けた始点 x=83 が帯の中(実測の帯は 218)。縦向きは inset 0 = 従来と同じ。欄が無い版は 0
        let leftInset = max(doubleValue(named: "mLeftInset", in: block) ?? 0, 0)
        let rightInset = max(doubleValue(named: "mRightInset", in: block) ?? 0, 0)
        let reported = doubleValue(named: "mBottomGestureHeight", in: block)
        let bottom = reported.flatMap { $0 > 0 ? $0 : nil } ?? max(bottomFallback, 0)
        return (left + leftInset, right + rightInset, bottom)
    }

    /// 帯を読む1回の結果(呼び手 = `AndroidDriver.backGestureEdgeWidths`)。読めなかった理由を注記へ残すためだけに使う
    public enum ReadOutcome: Sendable {
        case timedOut(seconds: Double)
        case threw(String)
        case exited(status: Int32, output: String)
    }

    /// `parse` が nil になった回の理由(事実だけ: 期限切れか・失敗の終了か・出力のどこが欠けたかを分ける)。
    /// 読めた回(3ボタン navigation の (0,0,0) を含む)は nil
    public static func unreadReason(_ outcome: ReadOutcome, bottomFallback: Double = 0) -> String? {
        switch outcome {
        case .timedOut(let seconds):
            return "dumpsys did not answer within \(formatSeconds(seconds))s"
        case .threw(let message):
            return "adb could not be run: \(message)"
        case .exited(let status, let output):
            guard status == 0 else {
                return "dumpsys exited \(status) (\(output.utf8.count) bytes of output\(lastLine(output)))"
            }
            guard parse(output, bottomFallback: bottomFallback) == nil else { return nil }
            guard let block = block(named: "EdgeBackGestureHandler:", in: output) else {
                return "the output (\(output.utf8.count) bytes) has no EdgeBackGestureHandler block"
            }
            guard gestureEnabled(in: block) != nil else {
                return "the EdgeBackGestureHandler block (\(block.count) lines) has no gesture-enabled field"
            }
            return "the EdgeBackGestureHandler block (\(block.count) lines) has no mEdgeWidthLeft/mEdgeWidthRight value"
        }
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(format: "%.1f", seconds)
    }

    private static func lastLine(_ output: String) -> String {
        guard let line = output.split(separator: "\n").last?.trimmingCharacters(in: .whitespaces), !line.isEmpty
        else { return "" }
        return ", last line: \(line.prefix(120))"
    }

    /// 有効かの欄の名前は OS の版で違う。**両方あれば `mIsGestureHandlingEnabled` を優先**(Android 15 の実測の形)。
    /// どちらも無ければ nil(除外しない側に倒す)
    private static func gestureEnabled(in block: [Substring]) -> Bool? {
        boolValue(named: "mIsGestureHandlingEnabled", in: block) ?? boolValue(named: "mIsGesturalModeEnabled", in: block)
    }

    /// ヘッダ行より深いインデントの行だけをブロックとして切り出す(次に同じ/浅いインデントの
    /// 非空行が来たら終端)。**ただし字下げの崩れた1行は続きとして読む**: 浅い行が `key=value` の形で、
    /// 次の非空行がまたブロックの字下げへ戻るとき(実測: 6 文字のはずの `mIsAttached=true` が 2 文字で出て、
    /// ブロックが 1 行で切れ、有効の欄に届かず帯を避けなかった。同じ端末で 48 回中 1 回)。
    /// 戻らない浅い行(ブロックの後の親の欄・次の見出し)は今までどおり終端
    private static func block(named header: String, in dumpsys: String) -> [Substring]? {
        let lines = dumpsys.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(header)
        }) else { return nil }
        let headerIndent = indent(of: lines[start])
        let rest = lines[(start + 1)...].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var body: [Substring] = []
        for (offset, line) in rest.enumerated() {
            if indent(of: line) > headerIndent {
                body.append(line)
                continue
            }
            let next = offset + 1 < rest.count ? rest[rest.startIndex + offset + 1] : nil
            guard isKeyValueLine(line), let next, indent(of: next) > headerIndent else { break }
            body.append(line)
        }
        return body
    }

    /// `name=value` の形の行(見出し `Name:` ではない)
    private static func isKeyValueLine(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let eq = trimmed.firstIndex(of: "="), eq != trimmed.startIndex else { return false }
        return !trimmed[..<eq].contains(" ") && !trimmed.hasSuffix(":")
    }

    private static func indent(of line: Substring) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private static func rawValue(named key: String, in block: [Substring]) -> String? {
        for line in block {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key)=") else { continue }
            return String(trimmed.dropFirst(key.count + 1))
        }
        return nil
    }

    private static func boolValue(named key: String, in block: [Substring]) -> Bool? {
        switch rawValue(named: key, in: block) {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    private static func doubleValue(named key: String, in block: [Substring]) -> Double? {
        rawValue(named: key, in: block).flatMap(Double.init)
    }
}
