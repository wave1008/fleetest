// findEditable は shortId の id が木のどこにも無いとき座標の欄(editableAt)へ落ちず null を返す(ソース走査。ブリッジはデバイスでしか動かない)。

import XCTest

final class OI381FindEditableSourceTests: XCTestCase {

    func testFindEditableDoesNotFallToCoordinatesWhenIdIsGoneFromTree() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AndroidRunner/src/com/example/ftbridge/InputInjector.java")
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let r = source.range(of: "private static AccessibilityNodeInfo findEditable(") else {
            return XCTFail("findEditable が見つからない")
        }
        let body = String(source[r.upperBound...].prefix(1400))
        guard let guardAt = body.range(of: "if (!hasNodeWithId(root, shortId)) return null;"),
              let fallAt = body.range(of: "return editableAt(root, x, y, tmp);") else {
            return XCTFail("id 不在の null 返しか editableAt の落ち先が見つからない")
        }
        XCTAssertLessThan(guardAt.lowerBound, fallAt.lowerBound, "id 不在の判定は座標への落ちより前")
    }
}
