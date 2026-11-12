// pickerWheel を値で合わせる 2 本のワイヤ。iOS = POST /pickerValue(ホストが候補を組み、ランナーの値を `PickerValueMatch` で照合する)・
// Android = POST /pickerStep(1段ずつ送って読み返す)。ドライバの層は素通し(AppAttachDriver は 501 に落とさない)。

import XCTest
@testable import FTBridgeClient
import FTCore

final class PickerValueWireTests: XCTestCase {

    private let frame = FTRect(x: 10, y: 20, width: 100, height: 40)

    private func client(_ stub: RecordingStubServer) -> BridgeClient {
        BridgeClient(port: stub.port, interactionTimeout: 5, sessionTimeout: 5)
    }

    func testIOSSendsFrameAndCandidatesAndAcceptsAMatchingValue() async throws {
        let stub = try RecordingStubServer(body: #"{"matched":"19","value":"19時","tried":["19"]}"#)
        defer { stub.stop() }
        let outcome = try await client(stub).setPickerValue(ref: 3, frame: frame, identifier: nil,
                                                            currentValue: "14時", value: "19")
        XCTAssertEqual(outcome.value, "19時")
        XCTAssertEqual(stub.paths, ["POST /pickerValue"])
        let sent = try JSONDecoder().decode(PickerValueRequest.self,
                                            from: Data(try XCTUnwrap(stub.body(for: "POST /pickerValue")).utf8))
        XCTAssertEqual(sent.candidates, ["19", "19時"], "行の文字の形の候補も送る")
        XCTAssertEqual(sent.frame, frame, "ref ではなく frame で指す(inapp-boost モードの ref は別名前空間)")
    }

    func testIOSFailsWithTheValueItStoppedAt() async throws {
        let stub = try RecordingStubServer(body: #"{"value":"14時","tried":["19","19時"],"note":"boom"}"#)
        defer { stub.stop() }
        do {
            _ = try await client(stub).setPickerValue(ref: 3, frame: frame, identifier: nil,
                                                      currentValue: "14時", value: "19")
            XCTFail("合っていない値は失敗にする")
        } catch DriverError.badResponse(let status, let body) {
            XCTAssertEqual(status, 422)
            XCTAssertTrue(body.contains("stopped at '14時'") && body.contains("'19'") && body.contains("boom"), body)
        }
    }

    func testIOSFailsWhenTheValueCannotBeRead() async throws {
        let stub = try RecordingStubServer(body: #"{"tried":["19"]}"#)
        defer { stub.stop() }
        do {
            _ = try await client(stub).setPickerValue(ref: 3, frame: frame, identifier: nil, currentValue: nil, value: "19")
            XCTFail()
        } catch DriverError.badResponse(let status, let body) {
            XCTAssertEqual(status, 422)
            XCTAssertTrue(body.contains("could not be read"), body)
        }
    }

    func testAndroidStepWire() async throws {
        let stub = try RecordingStubServer(body: #"{"performed":true,"value":"15"}"#)
        defer { stub.stop() }
        let result = try await client(stub).pickerStep(ref: 7, direction: .forward)
        XCTAssertEqual(result, PickerStepResult(performed: true, value: "15"))
        let sent = try JSONDecoder().decode(PickerStepRequest.self,
                                            from: Data(try XCTUnwrap(stub.body(for: "POST /pickerStep")).utf8))
        XCTAssertEqual(sent.ref, 7)
        XCTAssertEqual(sent.direction, "forward")
    }

    /// AppAttachDriver(inapp-boost モードで XCUITest ブリッジへ回る口)は既定の 501 に落ちず、ランナーへ届く
    func testAppAttachDriverForwardsInsteadOfFalling501() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTBridgeClient/AppAttachDriver.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("client.setPickerValue("), "AppAttachDriver が setPickerValue を素通ししていない")
        XCTAssertTrue(source.contains("func setPickerValue("))
        let hybrid = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTBridgeClient/HybridFallbackDriver.swift"), encoding: .utf8)
        XCTAssertTrue(hybrid.contains("$0.setPickerValue("), "HybridFallbackDriver が fallback へ回していない")
    }
}
