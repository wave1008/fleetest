// 木の幾何(枠・点)を `Int(...)` で素に変換しない(in-app ブリッジが `CGRect.infinite` 相当の枠を返した要素で
// `contentSignature` がトラップし、シナリオのプロセスごと落ちた)。変換は `Int(saturating:)`(SaturatingInt.swift)

import Foundation
import XCTest
@testable import FTCore

final class SaturatingIntScanTests: XCTestCase {

    func testSaturatesInsteadOfTrapping() {
        XCTAssertEqual(Int(saturating: -8.98846567431158e307), .min)
        XCTAssertEqual(Int(saturating: Double.infinity), .max)
        XCTAssertEqual(Int(saturating: -Double.infinity), .min)
        XCTAssertEqual(Int(saturating: Double.nan), 0)
        XCTAssertEqual(Int(saturating: 9.223372036854775807e18), .max)
        XCTAssertEqual(Int(saturating: 12.9), 12)
        XCTAssertEqual(Int(saturating: -12.9), -12)
    }

    /// `CGRect.infinite` の枠(原点 -greatestFiniteMagnitude/2・幅 greatestFiniteMagnitude)を持つ要素で落ちない
    func testContentSignatureSurvivesAnInfiniteFrame() {
        let half = -Double.greatestFiniteMagnitude / 2
        let element = ElementInfo(ref: 0, type: "Other", identifier: nil, label: nil, value: nil, placeholder: nil,
                                  enabled: true,
                                  frame: FTRect(x: half, y: half, width: .greatestFiniteMagnitude,
                                                height: .greatestFiniteMagnitude),
                                  depth: 0)
        XCTAssertFalse(StepExecutor.contentSignature([element]).isEmpty)
        XCTAssertTrue(StepExecutor.sameContent([element], [element]))
    }

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    /// 枠・点の成分(`.x` / `.width` / `.centerY` …。`.rounded()` 付きも)を素の `Int(` に渡している行
    static let rawGeometryConversion = try! NSRegularExpression(
        pattern: #"\bInt\(\s*[\$A-Za-z0-9_][\w\.\$]*\.(x|y|width|height|minX|minY|maxX|maxY|midX|midY|centerX|centerY)(\.rounded\([^()]*\))?\s*[\)\+\-\*/]"#)

    static func rawConversions(in text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
            let line = String(raw)
            let code = line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
            let range = NSRange(code.startIndex..., in: code)
            return rawGeometryConversion.firstMatch(in: code, range: range) == nil ? nil : line
        }
    }

    func testPatternCatchesTheShapesThatTrapped() {
        XCTAssertEqual(Self.rawConversions(in: #"text += "|\(Int(frame.x)),\(Int(frame.y))""#).count, 1)
        XCTAssertEqual(Self.rawConversions(in: "hasher.combine(Int(element.frame.x.rounded()))").count, 1)
        XCTAssertEqual(Self.rawConversions(in: #"map { "\(Int($0.width))" }"#).count, 1)
        XCTAssertEqual(Self.rawConversions(in: #""\(Int(band.y + band.height))""#).count, 1)
        XCTAssertTrue(Self.rawConversions(in: #""\(Int(saturating: frame.x))""#).isEmpty)
        XCTAssertTrue(Self.rawConversions(in: "let n = Int(parts.count)").isEmpty)
    }

    func testSourcesDoNotConvertGeometryWithPlainInt() throws {
        let root = Self.sourcesRoot
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var scanned = 0
        var hits: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            scanned += 1
            for line in Self.rawConversions(in: text) {
                hits.append("\(url.path.replacingOccurrences(of: root.path + "/", with: "")): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertGreaterThan(scanned, 100, "the scan did not reach Sources")
        XCTAssertEqual(hits, [], "convert tree geometry with Int(saturating:) — Int(_:) traps on a non-finite or huge frame")
    }
}
