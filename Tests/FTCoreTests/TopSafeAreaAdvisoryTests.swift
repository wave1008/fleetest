// 画面上端の安全領域(ステータスバー・ノッチ・Dynamic Island の帯)に中心が入る対象への警告(OI-1)と、
// その申告 `SnapshotResponse.safeAreaTop` のワイヤ形式。帯の高さは木に載らないので定数を持たず、申告だけで決める。

import XCTest
@testable import FTCore

final class TopSafeAreaAdvisoryTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    private func element(y: Double, h: Double) -> ElementInfo {
        ElementInfo(ref: 1, type: "button", identifier: "back", label: "Back", value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 16, y: y, width: 85, height: h), depth: 2)
    }

    func testCentreInsideTheMeasuredBandIsCalledOut() {
        // 申告 62(帯 0..62)・要素 (16,-2 85x18) の中心 y=7 → 帯の中(OI-1 の「◀ 前のアプリ」の形)
        let note = TapTargetGeometry.topSafeAreaAdvisory(
            for: element(y: -2, h: 18), safeAreaTop: .measured(62), screen: screen)
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains("(58, 7)") == true, note ?? "")
        XCTAssertTrue(note?.contains("top 62") == true, note ?? "")
    }

    func testCentreJustBelowTheBandStaysSilent() {
        // 中心 y = 62 ちょうどは帯の外(帯は [0, 62))
        XCTAssertNil(TapTargetGeometry.topSafeAreaAdvisory(
            for: element(y: 52, h: 20), safeAreaTop: .measured(62), screen: screen))
    }

    func testUnknownAndZeroSayNothing() {
        let inBand = element(y: 0, h: 20)
        XCTAssertNil(TapTargetGeometry.topSafeAreaAdvisory(for: inBand, safeAreaTop: .unknown, screen: screen))
        XCTAssertNil(TapTargetGeometry.topSafeAreaAdvisory(for: inBand, safeAreaTop: .measured(0), screen: screen))
    }

    func testCentreAboveTheScreenIsLeftToTheOffscreenAdvisory() {
        XCTAssertNil(TapTargetGeometry.topSafeAreaAdvisory(
            for: element(y: -60, h: 20), safeAreaTop: .measured(62), screen: screen))
    }

    /// 共有チェーンでは帯が幾何の助言より先に言う
    func testTheSharedChainReportsTheBand() {
        let el = element(y: 0, h: 20)
        let note = TapTargetGeometry.advisory(
            for: el, in: [el], screen: screen, keyboardOcclusion: .none, overlayWindows: .none,
            safeAreaTop: .measured(62), isAndroid: false)
        XCTAssertTrue(note?.contains("safe-area band") == true, note ?? "")
    }

    /// 帯は鎖の最後: 無効な要素が帯にあれば「無効」を言う
    func testTheBandDoesNotHideAMoreSpecificAdvisory() {
        let el = ElementInfo(ref: 1, type: "button", identifier: "back", label: "Back", value: nil,
                             placeholder: nil, enabled: false,
                             frame: FTRect(x: 16, y: 0, width: 85, height: 20), depth: 2)
        let note = TapTargetGeometry.advisory(
            for: el, in: [el], screen: screen, keyboardOcclusion: .none, overlayWindows: .none,
            safeAreaTop: .measured(62), isAndroid: false)
        XCTAssertTrue(note?.contains("disabled") == true, note ?? "")
    }

    // MARK: ワイヤ形式

    func testWireRoundTripKeepsMeasuredAndUnknownApart() throws {
        let measured = SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [], truncatedCount: 0,
                                        safeAreaTop: .measured(62))
        let data = try JSONEncoder().encode(measured)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"measured\":true"))
        XCTAssertEqual(try JSONDecoder().decode(SnapshotResponse.self, from: data).safeAreaTop, .measured(62))

        let unknown = SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [], truncatedCount: 0)
        let unknownData = try JSONEncoder().encode(unknown)
        XCTAssertTrue(String(decoding: unknownData, as: UTF8.self).contains("\"measured\":false"),
                      "不明は欄の省略ではなく明示で送る")
        XCTAssertEqual(try JSONDecoder().decode(SnapshotResponse.self, from: unknownData).safeAreaTop, .unknown)
    }

    func testMeasuredWithoutTopIsRejected() {
        let json = #"{"screen":{"x":0,"y":0,"width":1,"height":1},"elements":[],"truncatedCount":0,"safeAreaTop":{"measured":true}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(SnapshotResponse.self, from: Data(json.utf8)))
    }

    /// 固定コーパス(欄ができる前の生 JSON)は不明と読む
    func testTheFieldIsRequired() {
        let json = #"{"screen":{"x":0,"y":0,"width":390,"height":844},"elements":[],"truncatedCount":0}"#
        XCTAssertThrowsError(try JSONDecoder().decode(SnapshotResponse.self, from: Data(json.utf8)),
                             "欄の欠落を黙って不明と読まない(ブリッジは必ず送る)")
    }

    // MARK: 配線(3つのブリッジが必ず送る・ホストの全呼び手が申告を渡す)

    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testAllThreeBridgesAlwaysSendTheField() throws {
        XCTAssertTrue(try read("InAppBridge/Sources/InAppBridge.swift").contains("safeAreaTop: safeAreaTop"))
        XCTAssertTrue(try read("Runner/FleetestRunnerUITests/BridgeRouter.swift").contains("safeAreaTop: .unknown"))
        XCTAssertTrue(try read("AndroidRunner/src/com/example/ftbridge/SnapshotBuilder.java")
            .contains("response.put(\"safeAreaTop\", safeAreaTopJSON(context))"))
    }

    func testHostCallersPassTheSnapshotsDeclaration() throws {
        for site in ["Sources/FTCore/StepExecutor+Actions.swift", "Sources/FTCore/StepExecutor+Hold.swift",
                     "Sources/fleetest-mcp/MCPServer+Snapshot.swift",
                     "Sources/fleetest-mcp/MCPServer+GesturesTools.swift"] {
            let text = try read(site)
            XCTAssertTrue(text.contains("safeAreaTop: snapshot.safeAreaTop")
                          || text.contains("safeAreaTop: fresh.safeAreaTop")
                          || text.contains("snapshot?.safeAreaTop"),
                          "\(site) がスナップショットの safeAreaTop を渡していない")
        }
    }
}
