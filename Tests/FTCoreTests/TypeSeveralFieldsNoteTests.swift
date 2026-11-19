// type のセレクタが入力欄に複数当たったときの注記。破ると: 標準アプリのリマインダーで、残っていた行の題名の欄へ
// 黙って追記し続ける形が文言から読めない
import XCTest
@testable import FTCore

final class TypeSeveralFieldsNoteTests: XCTestCase {
    private func field(_ ref: Int, y: Double, value: String? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: "textField", identifier: nil, label: "タイトル", value: value, placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: y, width: 400, height: 44), depth: 2)
    }

    func testSeveralMatchingFieldsAreNamed() {
        let elements = [field(1, y: 300, value: "牛乳を買う"), field(2, y: 344)]
        let note = StepExecutor.severalFieldsMatchedNote(FlowStep(action: "type", locator: FlowLocator(label: "タイトル")), in: elements)
        XCTAssertTrue(note.contains("matches 2 input fields"), note)
    }

    func testOneFieldOrAnIndexAddsNothing() {
        XCTAssertEqual(StepExecutor.severalFieldsMatchedNote(
            FlowStep(action: "type", locator: FlowLocator(label: "タイトル")), in: [field(1, y: 300, value: "x")]), "")
        var indexed = FlowLocator(label: "タイトル")
        indexed.index = 1
        XCTAssertEqual(StepExecutor.severalFieldsMatchedNote(
            FlowStep(action: "type", locator: indexed), in: [field(1, y: 300, value: "x"), field(2, y: 344)]), "")
    }
}
