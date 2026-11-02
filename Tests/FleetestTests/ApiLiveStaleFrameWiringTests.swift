import XCTest

/// LIVE-3: 鮮度判定(LiveStaleFrameTracker)は絵と木の両方を撮る emitObservation で行うことをソース走査で縛る。
/// 判定そのものの単体テストは LiveStaleFrameTrackerTests。
final class ApiLiveStaleFrameWiringTests: XCTestCase {

    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/ApiLiveCommand.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// emitObservation は撮影した生 PNG(縮小前)と、そのすぐ後に撮った木(snap.elements)を渡し、
    /// 結果を snapshot イベントの notes へ載せること
    func testEmitObservationFeedsRawPNGAndFreshElementsIntoTheTracker() throws {
        let code = try source()
        guard let start = code.range(of: "private func emitObservation("),
              let end = code.range(of: "private func followFrontmost(") else {
            return XCTFail("emitObservation / followFrontmost が見当たらない — テストを見直すこと")
        }
        let body = String(code[start.upperBound..<end.lowerBound])
        XCTAssertTrue(
            body.contains("staleFrameTracker.staleNotes(png: png, elements: snap.elements)"),
            "emitObservation は撮影した生 PNG とその直後の木を LiveStaleFrameTracker へ渡すこと"
            + "(縮小後の JPEG や古い木を渡すと画像ハッシュ・木指紋の比較が壊れる)")
        XCTAssertTrue(body.contains("notes: notes"),
                      "鮮度注記を ApiLiveSnapshotEvent(ok:true側)へ渡していない")
    }

    /// handle が emitObservation に staleFrameTracker を渡していること(呼び出し側の配線)
    func testHandlePassesTheTrackerToEmitObservation() throws {
        let code = try source()
        guard let observationCallRange = code.range(
            of: "await emitObservation(driver: driver, starter: starter, follower: follower, port: port,")
        else {
            return XCTFail("handle 内の emitObservation 呼び出しが見当たらない — テストを見直すこと")
        }
        let tail = String(code[observationCallRange.upperBound...].prefix(80))
        XCTAssertTrue(tail.contains("staleFrameTracker: staleFrameTracker"),
                      "handle は emitObservation に staleFrameTracker を渡すこと")
    }
}
