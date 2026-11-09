import Foundation
import XCTest
@testable import FTCore

/// 「空」は `TextNormalization.isBlank` の1か所だけ(セレクタ・値の検証が共有)(空白・改行・タブだけは空)。場所ごとに `.whitespaces` などで書くと
/// 漏れる形が残る(41〜44周目に空の期待値・`=`・空白・改行と経路を変えて4度、誤った緑が出た)
final class SelectorBlankSingleSourceTests: XCTestCase {
    /// 空の判定の除外は一致の判定(TextNormalization.text)と同じ = 一致で消える文字だけの値は空
    func testInvisibleRuleIsSharedWithMatching() {
        for invisible in ["\u{200B}", "\u{FEFF}\u{2060}", "\u{00AD}", "\u{200E}\u{200F}", "\u{0007}"] {
            XCTAssertEqual(TextNormalization.text.apply(invisible), "", invisible.debugDescription)
            XCTAssertTrue(FTSelector.isBlank(invisible), invisible.debugDescription)
        }
    }

    func testBlankCoversSpacesNewlinesAndTabs() {
        // 半角・全角・NBSP・改行・タブ・ゼロ幅(ZWSP・ZWJ・語結合子・BOM)・モンゴル語の母音区切り・段落区切り
        for blank in ["", " ", "\n", "\r\n", "\t", " \n\t", "\u{3000}", "\u{00A0}", "\u{200B}", "\u{200D}", "\u{2060}",
                      "\u{FEFF}", "\u{180E}", "\u{2029}", "\u{000B}\u{000C}", " \u{200B}\u{3000}\n"] {
            XCTAssertTrue(FTSelector.isBlank(blank), blank.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " "))
        }
        // 見た目の文字と1文字を作る結合子・異体字セレクタは除外しない(一致の判定と同じ規則)= 文字が残るので空ではない
        for nonBlank in [" a ", "\u{200B}x", "\n0\n", "・", "❤\u{FE0F}", "👨\u{200D}👩"] {
            XCTAssertFalse(FTSelector.isBlank(nonBlank), nonBlank.debugDescription)
        }
    }

    /// 検証のファイルに素の「詰めて空か」を書かない
    func testNoAdHocBlankChecksInSelectorValidation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pattern = try NSRegularExpression(pattern: #"trimmingCharacters\(in:\s*\.[a-zA-Z]+\)\s*\.isEmpty"#)
        var hits: [String] = []
        for file in ["Sources/FTCore/FTSelector.swift", "Sources/FTDSL/Sel.swift", "Sources/FTDSL/ValueAssertions.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertGreaterThan(source.count, 1000, "\(file) を読めていない")
            for (index, line) in source.components(separatedBy: "\n").enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                if pattern.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                    hits.append("\(file):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(hits, [], "空の判定は TextNormalization.isBlank を通す:\n" + hits.joined(separator: "\n"))
    }
}
