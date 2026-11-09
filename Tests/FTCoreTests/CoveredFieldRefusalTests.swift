import XCTest
@testable import FTCore

/// 打つ・消す欄の中心が手前の要素に覆われているとき、撃つ前に断る(tap の `coveredTouchPlan` と同じ判定)。
/// clearInput と type(replace:) は `performClearInput` を通る。ここで落とす = 「裏の空の欄を消せた」と緑になる
final class CoveredFieldRefusalTests: XCTestCase {
    private let screen = FTRect(x: 0, y: 0, width: 1080, height: 2400)

    private func executor() -> StepExecutor {
        StepExecutor(driver: FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[]]),
                     isAndroid: false, tunables: RunTunables())
    }

    private func el(_ ref: Int, _ type: String, id: String, _ r: FTRect, z: Int, focused: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: id, value: nil, placeholder: nil, enabled: true,
                    frame: r, depth: 2, focused: focused, z: z)
    }

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements, truncatedCount: 0)
    }

    private func step() -> FlowStep { FlowStep(action: "clearInput", locator: FlowLocator(id: "field_search")) }

    func testFieldWithItsCentreCoveredIsRefusedBeforeClearing() async {
        let field = el(1, "textField", id: "field_search", FTRect(x: 48, y: 396, width: 1184, height: 168), z: 1)
        let cover = el(2, "button", id: "search_view", FTRect(x: 0, y: 300, width: 1080, height: 400), z: 2)
        let r = await executor().coveredFieldRefusal(field, in: snapshot([field, cover]), step: step(), verb: "clear")
        XCTAssertTrue(r?.contains("covered by") == true, r ?? "nil")
        XCTAssertTrue(r?.contains("nothing was") == true, r ?? "nil")
    }

    func testUncoveredFieldIsNotRefused() async {
        let field = el(1, "textField", id: "field_search", FTRect(x: 48, y: 396, width: 1000, height: 168), z: 2)
        let other = el(2, "button", id: "search_view", FTRect(x: 0, y: 1000, width: 1080, height: 400), z: 1)
        let r = await executor().coveredFieldRefusal(field, in: snapshot([field, other]), step: step(), verb: "clear")
        XCTAssertNil(r)
    }

    /// 焦点がすでにその欄にあるキーボード表示中は、触らずに撃つので覆いの判定を飛ばす
    func testFocusedFieldWithKeyboardUpSkipsTheCheck() async {
        let field = el(1, "textField", id: "field_search", FTRect(x: 48, y: 396, width: 1184, height: 168), z: 1, focused: true)
        let cover = el(2, "button", id: "search_view", FTRect(x: 0, y: 300, width: 1080, height: 400), z: 2)
        var snap = snapshot([field, cover])
        snap.keyboardFrame = FTRect(x: 0, y: 1600, width: 1080, height: 800)
        let r = await executor().coveredFieldRefusal(field, in: snap, step: step(), verb: "clear")
        XCTAssertNil(r)
    }

    func testPerformClearInputConsultsTheCoveredFieldCheck() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/StepExecutor+TypeClear.swift"), encoding: .utf8)
        let start = try XCTUnwrap(src.range(of: "func performClearInput(element:"))
        XCTAssertTrue(String(src[start.upperBound...].prefix(2500)).contains("coveredFieldRefusal("))
    }

    func testAndroidStaticTextClearInputIsRefusedBeforeFiring() {
        let e = ElementInfo(ref: 1, type: "staticText", identifier: "txt", label: nil, value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)
        let android = StepExecutor(driver: FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[]]),
                                   isAndroid: true, tunables: RunTunables())
        let r = android.nonTextInputPreflightRefusal(e, in: [e], action: "clearInput")
        XCTAssertTrue(r?.contains("refusing before anything is cleared") == true, r ?? "nil")
        XCTAssertFalse(r?.contains("bridge") == true)
    }
}
