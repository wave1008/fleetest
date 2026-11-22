// 実行ログの開始の見出しは、バリアントの run で `ID@variant` を出す(同じ ID の単位が並んでも区別できる)。
// バリアントの無い run は ID だけ(今の形のまま)。

import XCTest
@testable import FTCore

final class RunLogFormatterVariantTests: XCTestCase {

    private func headline(variant: String?) -> String? {
        let item = ScenarioRunItem(info: ScenarioInfo(id: "C.S0010", title: "t"), variant: variant)
        return RunLogFormatter.lines(for: .flowStarted(worker: "W1", flowURL: item.url, flowName: item.info.id,
                                                       isDirty: false)).first
    }

    func testVariantRunShowsUnitKey() {
        XCTAssertEqual(headline(variant: "dark"), "▶ C.S0010@dark [W1]")
    }

    func testRunWithoutVariantKeepsID() {
        XCTAssertEqual(headline(variant: nil), "▶ C.S0010 [W1]")
    }

    func testVariantReadsBackFromURLWithLaneAndRepeat() {
        let url = ScenarioRunItem.url(for: "C.S0010", lane: "Pixel (A)&1", repeatIndex: 2, variant: "big-text")
        XCTAssertEqual(ScenarioRunItem.variant(in: url), "big-text")
        XCTAssertNil(ScenarioRunItem.variant(in: ScenarioRunItem.url(for: "C.S0010", lane: "x", variant: nil)))
    }
}
