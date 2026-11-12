// ft_set_picker_value: selector(または ref)で pickerWheel を指し、DSL と同じドライバ経路(`setPickerValue`)で合わせる。
// pickerWheel 以外は撃たずに断り、失敗は止まった値を運び、下書きは `setPickerValue("<selector>", "<value>")` の行になる。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPSetPickerValueTests: XCTestCase {

    private func wheel(_ ref: Int, id: String, value: String, y: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: "pickerWheel", identifier: id, label: nil, value: value, placeholder: nil,
                    enabled: true, frame: FTRect(x: 0, y: y, width: 200, height: 40), depth: 1)
    }

    private func make() -> (MCPServer, FakeDriver) {
        let fake = FakeDriver()
        fake.foregroundBundleID = "com.example.app"
        fake.snapshotResponse.elements = [
            wheel(1, id: "hour", value: "14時", y: 0),
            wheel(2, id: "minute", value: "00分", y: 60),
            ElementInfo(ref: 3, type: "button", identifier: "ok", label: "OK", value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 0, y: 120, width: 100, height: 40), depth: 1),
        ]
        let server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
        return (server, fake)
    }

    private func texts(_ result: [[String: Any]]) -> String {
        result.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    func testSelectorFiresTheDriverWithTheTreesCurrentValue() async throws {
        let (server, fake) = make()
        let text = texts(try await server.call(tool: "ft_set_picker_value", args: ["selector": "#hour", "value": "19"]))
        XCTAssertTrue(fake.calls.contains("setPickerValue(ref:1,id:hour,current:14時,value:19)"), "\(fake.calls)")
        XCTAssertTrue(text.contains("now reads \"19\""), text)
    }

    /// ref で撃つときも、ブリッジへはその木の番号で渡す(セッションの ref は木が変わると番号がずれる = 実測で別の要素(Button)を指した)
    func testRefIsSentToTheDriverInTheBridgesNumbering() async throws {
        let (server, fake) = make()
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        // 木が変わる(先頭に要素が1つ増える)= セッションの番号の世代が進む。ブリッジの番号では時のホイールは 2
        var changed = fake.snapshotResponse
        changed.elements = [ElementInfo(ref: 1, type: "staticText", identifier: "title", label: "時刻", value: nil, placeholder: nil,
                                        enabled: true, frame: FTRect(x: 0, y: -60, width: 100, height: 40), depth: 1),
                            wheel(2, id: "hour", value: "14時", y: 0), wheel(3, id: "minute", value: "00分", y: 60)]
        fake.snapshotResponse = changed
        let second = texts(try await server.call(tool: "ft_snapshot", args: [:]))
        let line = try XCTUnwrap(second.split(separator: "\n").first { $0.contains("pickerWheel") && $0.contains("hour") })
        let sessionRef = try XCTUnwrap(Int(line.dropFirst().prefix { $0.isNumber }))
        XCTAssertNotEqual(sessionRef, 2, "セッションの番号がブリッジの番号と同じ(テストの前提が崩れている)")
        _ = try await server.call(tool: "ft_set_picker_value", args: ["ref": sessionRef, "value": "19"])
        XCTAssertTrue(fake.calls.contains { $0.hasPrefix("setPickerValue(ref:2,") }, "\(fake.calls)")
    }

    func testRefusesAnythingButAPickerWheelWithoutSending() async throws {
        let (server, fake) = make()
        do {
            _ = try await server.call(tool: "ft_set_picker_value", args: ["selector": "#ok", "value": "19"])
            XCTFail("pickerWheel 以外は断る")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("is a button"), error.localizedDescription)
        }
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("setPickerValue(") }, "\(fake.calls)")
    }

    func testRequiresANonEmptyValue() async throws {
        let (server, fake) = make()
        for args: [String: Any] in [["selector": "#hour"], ["selector": "#hour", "value": "  "]] {
            do {
                _ = try await server.call(tool: "ft_set_picker_value", args: args)
                XCTFail("value が無い・空は断る: \(args)")
            } catch {}
        }
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("setPickerValue(") })
    }

    func testFailureCarriesTheValueTheWheelStoppedAt() async throws {
        let (server, fake) = make()
        fake.scriptedPickerFailure = "the picker stopped at '14時', not '99'"
        do {
            _ = try await server.call(tool: "ft_set_picker_value", args: ["selector": "#hour", "value": "99"])
            XCTFail()
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("stopped at '14時'"), error.localizedDescription)
        }
    }

    func testDraftWritesTheSelectorLine() async throws {
        let (server, _) = make()
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        _ = try await server.call(tool: "ft_set_picker_value", args: ["selector": "#minute", "value": "30"])
        let draft = texts(try await server.call(tool: "ft_draft_scenario", args: ["all": true]))
        XCTAssertTrue(draft.contains("setPickerValue(\"#minute\", \"30\")"), draft)
    }

    func testBatchLineBuildsTheStep() async throws {
        let (server, fake) = make()
        _ = try await server.call(tool: "ft_batch", args: ["steps": "setPickerValue '#hour' '19'"])
        XCTAssertTrue(fake.calls.contains { $0.hasPrefix("setPickerValue(ref:1,") }, "\(fake.calls)")
    }
}
