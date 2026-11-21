import XCTest
@testable import FTDSL

/// レポートのファイル名に入るシナリオ ID の形。拡張の `scenarioReports.test.mjs` の同じ表と一致させる(拡張はこの名前でレポートを探す)
final class ReportSlugContractTests: XCTestCase {
    static let table: [(id: String, slug: String)] = [
        ("Demo.S0001", "Demo_S0001"),
        ("デモ_iOS設定.S0030", "デモ_iOS設定_S0030"),
        ("時計のストップウォッチを操作できること.S0010", "時計のストップウォッチを操作できること_S0010"),
        ("ああああああああああああああああああああああああああああああああああああああああ.S0010", "ああああああああああああああああああああああああああああああ_S0010"),
        ("foo bar", "foo_bar"),
    ]

    func testSlugMatchesTheExtensionTable() {
        for row in Self.table {
            XCTAssertEqual(ScenarioReportWriter.slug(row.id), row.slug, row.id)
        }
    }

    /// 最も長い画像の名前(`scenario-<stamp>-<slug>-scene<n>-step<m>-<slug>.png`)が NAME_MAX に収まる
    func testLongestImageNameFitsNameMax() {
        let slug = ScenarioReportWriter.slug(String(repeating: "あ", count: 200) + ".S0010")
        XCTAssertTrue(slug.hasSuffix("_S0010"))
        XCTAssertLessThanOrEqual(slug.utf8.count, ScenarioReportWriter.slugByteBudget)
        let name = "scenario-20261121-054714-678-\(slug)-scene99-step999-\(ScenarioReportWriter.slug(String(repeating: "い", count: 200))).png"
        XCTAssertLessThanOrEqual(name.utf8.count, 255)
    }
}
