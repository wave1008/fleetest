// 貼り付く見出しの注記(MCP)は、容器が scrollable を申告した要素の枠のときだけ出す。
// 破ると: 推定の容器(行そのもの)の上端の題名を「帯」と読み、同じ行の説明文・ボタンに「見出しの下」と言う(固定コーパスで 94 件)
import XCTest
@testable import FTCore

final class PinnedBandNoteCorpusTests: XCTestCase {
    func testRealAppCorpusOnlyNamesBandsOfDeclaredContainers() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RealAppSnapshots")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertGreaterThan(files.count, 40, "コーパスに届いていない")
        var fired: [String] = []
        for file in files {
            let snap = try JSONDecoder().decode(SnapshotResponse.self, from: Data(contentsOf: file))
            for e in snap.elements where TapTargetGeometry.pinnedBandNote(for: e, in: snap.elements, operation: "touch") != nil {
                fired.append("\(file.lastPathComponent): \(e.type) \(e.identifier ?? "-") \(e.label ?? "-")")
            }
        }
        // 基準: 申告された容器の帯 5 件(ios-browser_weather_weekly 2・ios-photos_grid 3 等)。増えたら1件ずつ見てから変える
        XCTAssertLessThanOrEqual(fired.count, 5, fired.joined(separator: "\n"))
    }

    /// 行の上端の題名が同じ行の説明文を覆う形(申告の無い推定の容器)には言わない
    func testRowTitleOverItsSummaryIsNotAStickyHeader() {
        func e(_ ref: Int, _ id: String, _ f: FTRect, _ label: String, depth: Int) -> ElementInfo {
            ElementInfo(ref: ref, type: "staticText", identifier: id, label: label, value: nil, placeholder: nil,
                        enabled: true, frame: f, depth: depth)
        }
        let rows = (0..<4).flatMap { i -> [ElementInfo] in
            let y = 800.0 + Double(i) * 231
            return [e(10 + i * 2, "title", FTRect(x: 147, y: y, width: 933, height: 162), "題名\(i)", depth: 3),
                    e(11 + i * 2, "summary", FTRect(x: 189, y: y + 120, width: 500, height: 54), "説明\(i)", depth: 3)]
        }
        for summary in rows where summary.identifier == "summary" {
            XCTAssertNil(TapTargetGeometry.pinnedBandNote(for: summary, in: rows, operation: "touch"))
        }
    }
}
