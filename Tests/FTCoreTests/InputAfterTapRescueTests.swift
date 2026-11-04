// `tap(欄)` の後の ref 無し入力(type / clearInput)が「叩いた欄」を見失わないことの固定。
//
// ①hideKeyboard は直前に叩いた欄の記憶を捨てない(捨てると ref 無し type の救済・断りが効かず、
//   前に焦点のあった別の欄へ打って緑になった)
// ②ref 無し clearInput も type と同じ救済(叩いた容器の中の唯一の入力欄を ref で消す)を通る
//   (通らないと焦点の残った別の欄を空にして緑になった)
// ③伏せ字の欄への追記の type は、焦点が ref の欄へ移ったかの門をランナーに持つ(ソース走査)

import XCTest
@testable import FTCore

final class InputAfterTapRescueTests: XCTestCase {

    private final class Driver: AppDriver, @unchecked Sendable {
        var elements: [ElementInfo]
        /// 読み返しを問題にしない(救済の入れ先だけを確かめる)
        var verifiesTypedText = true
        private(set) var typedRefs: [Int?] = []
        private(set) var clearedRefs: [Int?] = []
        init(elements: [ElementInfo]) { self.elements = elements }

        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "-", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws -> String? { nil }
        func uninstall(bundleID: String) async throws {}
        func launch(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { true }
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil,
                             screen: FTRect(x: 0, y: 0, width: 1080, height: 2400),
                             elements: elements, truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws { typedRefs.append(ref) }
        func clearInput(ref: Int?) async throws {
            clearedRefs.append(ref)
            if let ref, let index = elements.firstIndex(where: { $0.ref == ref }) { elements[index].value = nil }
        }
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private func container(ref: Int, id: String) -> ElementInfo {
        ElementInfo(ref: ref, type: "other", identifier: id, label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 42, y: 417, width: 996, height: 147), depth: 1)
    }

    private func field(ref: Int, id: String, y: Double, focused: Bool? = nil, value: String? = nil) -> ElementInfo {
        var element = ElementInfo(ref: ref, type: "textField", identifier: id, label: nil,
                                  value: value, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 42, y: y, width: 996, height: 144), depth: 2)
        element.focused = focused
        return element
    }

    /// 容器(ref 8)の中の欄(ref 9・焦点なし)と、容器の外で焦点を持つ別の欄(ref 10)
    private func makeDriver() -> Driver {
        Driver(elements: [container(ref: 8, id: "wrapped"),
                          field(ref: 9, id: "inner", y: 417, value: "WW"),
                          field(ref: 10, id: "other", y: 900, focused: true, value: "kb")])
    }

    // MARK: - ① hideKeyboard は叩いた欄の記憶を捨てない

    func testHideKeyboardBetweenTapAndTypeKeepsTheTappedField() async throws {
        let driver = makeDriver()
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "wrapped"), timeout: 1))
        _ = await executor.execute(FlowStep(action: "hideKeyboard"))

        let outcome = await executor.execute(FlowStep(action: "type", text: "W3"))

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.typedRefs, [9], "hideKeyboard を挟んでも叩いた容器の中の欄へ入れること(捨てると焦点の欄 = nil へ打つ)")
        XCTAssertTrue(outcome.notes.contains(.typeFocusRecovered))
    }

    /// 対照: 焦点を動かす操作(swipe)は従来どおり記憶を捨てる
    func testSwipeStillForgetsTheTap() async throws {
        let driver = makeDriver()
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "wrapped"), timeout: 1))
        _ = await executor.execute(FlowStep(action: "swipe", direction: "up"))

        _ = await executor.execute(FlowStep(action: "type", text: "x"))

        XCTAssertEqual(driver.typedRefs, [nil])
    }

    // MARK: - ② clearInput の救済

    func testRefLessClearInputClearsTheFieldInsideTheTappedContainer() async throws {
        let driver = makeDriver()
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "wrapped"), timeout: 1))

        let outcome = await executor.execute(FlowStep(action: "clearInput"))

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.clearedRefs, [9], "焦点の残った別の欄(nil = 焦点の欄)でなく容器の中の欄を消すこと")
        XCTAssertTrue((outcome.driverFallback ?? "").contains("#inner"), "どの欄を消したか名指しすること: \(outcome.driverFallback ?? "")")
    }

    /// hideKeyboard を挟んでも clearInput が同じ欄を消す(①と②の合わせ技 = 探索で踏んだ形)
    func testRefLessClearInputAfterHideKeyboardStillTargetsTheTappedContainer() async throws {
        let driver = makeDriver()
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "wrapped"), timeout: 1))
        _ = await executor.execute(FlowStep(action: "hideKeyboard"))

        _ = await executor.execute(FlowStep(action: "clearInput"))

        XCTAssertEqual(driver.clearedRefs, [9])
    }

    /// 叩いた欄自身が焦点を持っているなら従来どおり焦点の欄を消す(速い経路を壊さない)
    func testRefLessClearInputKeepsTheFastPathWhenTheTappedFieldHasFocus() async throws {
        let driver = Driver(elements: [field(ref: 9, id: "inner", y: 417, focused: true, value: "WW")])
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "inner"), timeout: 1))

        _ = await executor.execute(FlowStep(action: "clearInput"))

        XCTAssertEqual(driver.clearedRefs, [nil])
    }

    /// 入れ先が一意に決まらない(容器の中に欄が2つ)なら推測しない
    func testRefLessClearInputDoesNotGuessAmongSeveralFields() async throws {
        var wide = container(ref: 8, id: "form")
        wide.frame = FTRect(x: 0, y: 0, width: 1080, height: 2400)
        let driver = Driver(elements: [wide, field(ref: 9, id: "a", y: 417, value: "1"),
                                       field(ref: 10, id: "b", y: 900, focused: true, value: "2")])
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "form"), timeout: 1))

        _ = await executor.execute(FlowStep(action: "clearInput"))

        XCTAssertEqual(driver.clearedRefs, [nil])
    }

    // MARK: - ③ 伏せ字の欄への追記の type の焦点の門(ランナー)

    func testRunnerGuardsMaskedAppendTypeWithAFocusMoveCheck() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Runner/FleetestRunnerUITests/BridgeRouter+TextInput.swift"), encoding: .utf8)
        guard let body = source.range(of: "private func typeAndReadBack") else { return XCTFail("typeAndReadBack が見つからない") }
        let tail = String(source[body.upperBound...])
        XCTAssertTrue(tail.contains("try awaitFocusMovedForMaskedType("),
                      "追記の type が焦点の移動を確かめずに打つ(replace / clear の門だけでは伏せ字の欄の追記は別の欄へ入る)")
        XCTAssertTrue(source.contains("focus is still on another field, so typing now"),
                      "断りの文言が replace / clear の既存の断りと揃っていない")
    }
}
