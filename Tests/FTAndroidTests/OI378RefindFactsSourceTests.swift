// OI-378: 入力した欄を見つけ直せずに期限が来たとき、失敗文に「候補の数・タップ点・最寄りの editable の枠・見つけ直しが今拾うもの」を
// 添える(座標が外れたのか・欄が作り直されたのかを次の1回で分ける材料)。欄を1つも引けなかった場合(target == null)も対象。

import XCTest

final class OI378RefindFactsSourceTests: XCTestCase {

    private func injectorSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(
            "AndroidRunner/src/com/example/ftbridge/InputInjector.java"), encoding: .utf8)
    }

    func testRefindFactsAreAddedWhenTheFieldWasNeverFoundToo() throws {
        let source = try injectorSource()
        XCTAssertTrue(source.contains("refindFailed = (pinned != null && !fresh) || target == null;"),
                      "欄を1つも引けなかった周回が、見つけ直しの事実を添える対象から外れている")
        XCTAssertTrue(source.contains("(refindFailed ? refindFacts(ua, shortId, (int) x, (int) y) : \"\")"))
    }

    func testRefindFactsNameWhatFindEditablePicks() throws {
        let source = try injectorSource()
        XCTAssertTrue(source.contains("findEditable(root, shortId, x, y, new Rect())"))
        XCTAssertTrue(source.contains("findEditable now picks"))
    }
}
