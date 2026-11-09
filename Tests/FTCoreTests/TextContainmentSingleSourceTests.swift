import Foundation
import XCTest
@testable import FTCore

/// 検証の「含む」は `TextContainment.contains` の1か所だけ(空の期待値は「含む」)。素の `.contains(期待値)` を書くと否定形が
/// `contains("") == false` で黙って緑になる(41周目 `textContainsNot("")`・43周目 `thisContainsNot("")` と経路を変えて2度出た)
final class TextContainmentSingleSourceTests: XCTestCase {
    func testEmptyExpectationIsContained() {
        XCTAssertTrue(TextContainment.contains("abc", ""))
        XCTAssertTrue(TextContainment.contains("", ""))
        XCTAssertTrue(TextContainment.contains("abc", "b"))
        XCTAssertFalse(TextContainment.contains("abc", "x"))
    }

    /// 期待値の名前(expected / want / normalizedExpected)に素の `.contains(` を当てる行を落とす
    func testNoRawContainsOnExpectedValues() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // 理由付きの例外: imageIs のラベル照合は空の期待値で常に緑になる側へ倒さない(空は一致させない)
        let allowed: Set<String> = ["Sources/FTCore/TextContainment.swift", "Sources/FTCore/VisionClassifier.swift"]
        let pattern = try NSRegularExpression(pattern: #"\.contains\((expected|want|normalizedExpected)\)"#)
        var hits: [String] = []
        var scanned = 0
        for dir in ["Sources/FTCore", "Sources/FTDSL"] {
            let base = root.appendingPathComponent(dir)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let relative = dir + "/" + url.path.dropFirst(base.path.count + 1)
                scanned += 1
                guard !allowed.contains(relative) else { continue }
                let source = try String(contentsOf: url, encoding: .utf8)
                for (index, line) in source.components(separatedBy: "\n").enumerated() {
                    let code = line.components(separatedBy: "//").first ?? line
                    if pattern.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                        hits.append("\(relative):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                    }
                }
            }
        }
        XCTAssertGreaterThan(scanned, 100, "走査が Sources に届いていない")
        XCTAssertEqual(hits, [], "検証の「含む」は TextContainment.contains を通す:\n" + hits.joined(separator: "\n"))
    }
}
