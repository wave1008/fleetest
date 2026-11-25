// DR-231: 見えている幅か高さが文字を描けないほど小さい押せる要素の判定(`OcclusionEligibility.unreadableSliver`)。
import XCTest
@testable import FTCore

final class UnreadableSliverTests: XCTestCase {
    private func el(_ type: String, _ w: Double, _ h: Double, clickable: Bool? = nil) -> ElementInfo {
        var e = ElementInfo(ref: 1, type: type, identifier: nil, label: "タグ 04", value: nil, placeholder: nil,
                            enabled: true, frame: FTRect(x: 0, y: 0, width: w, height: h), depth: 0)
        e.clickable = clickable
        return e
    }

    /// 床の既定(8 pt/dp)を固定する: 他のテストが値を差し替えると既定を戻す変更が素通りする
    func testFloorIsEightPointsTimesScale() {
        XCTAssertEqual(OcclusionEligibility.unreadableSliver(el("clickable", 2, 154), scale: 1)?.floor, 8)
        XCTAssertEqual(OcclusionEligibility.unreadableSliver(el("clickable", 2, 154), scale: 2.625)?.floor, 21)
    }

    func testWidthOrHeightUnderFloorFires() {
        XCTAssertNotNil(OcclusionEligibility.unreadableSliver(el("clickable", 2, 154), scale: 2.625))
        XCTAssertNotNil(OcclusionEligibility.unreadableSliver(el("button", 154, 7), scale: 1))
    }

    /// 密度で換算する: 同じ 20 でも密度 1 なら床(8)以上・密度 2.625 なら床(21)未満
    func testScaleConvertsFloorToTreeUnits() {
        XCTAssertNil(OcclusionEligibility.unreadableSliver(el("clickable", 20, 154), scale: 1))
        XCTAssertNotNil(OcclusionEligibility.unreadableSliver(el("clickable", 20, 154), scale: 2.625))
    }

    func testNormalSizeDoesNotFire() {
        XCTAssertNil(OcclusionEligibility.unreadableSliver(el("button", 100, 40), scale: 1))
    }

    /// 文字の型(ink・OCR が読む)と押せない要素(細い進捗バー)は対象外。clickable の申告つきの別の型は対象
    func testTextTypesAndNonOperableAreOutOfScope() {
        var web = el("link", 7, 2); web.web = true
        XCTAssertNil(OcclusionEligibility.unreadableSliver(web, scale: 1))
        XCTAssertNil(OcclusionEligibility.unreadableSliver(el("staticText", 2, 154), scale: 1))
        XCTAssertNil(OcclusionEligibility.unreadableSliver(el("progressIndicator", 300, 4), scale: 1))
        XCTAssertNotNil(OcclusionEligibility.unreadableSliver(el("other", 2, 154, clickable: true), scale: 1))
    }

    /// 固定コーパスの全数: 発火の一覧を基準で固定する(2026-11-25 に1件ずつ見た → DR-231)。増えたら1件ずつ見て真陽性か確かめてから変える
    func testRealAppCorpusFiringsAreKnown() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RealAppSnapshots")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThan(files.count, 40)
        var fired: [String] = []
        for file in files where file.lastPathComponent.hasPrefix("and-") {
            let snap = try JSONDecoder().decode(SnapshotResponse.self, from: Data(contentsOf: file))
            // 木の単位: Android は px(密度は幅 411dp 換算)。iOS は呼び手が使わないので数えない(iOS 12 件のうち 9 件が Safari の画像地図のリンクの 3〜7pt)
            let scale = snap.screen.width / 411
            for e in snap.elements where !(e.label ?? "").isEmpty && OcclusionEligibility.unreadableSliver(e, scale: scale) != nil {
                fired.append("\(file.lastPathComponent): \(e.type) \(e.label ?? "") \(Int(e.frame.width))x\(Int(e.frame.height))")
            }
        }
        // 基準(2026-11-25): 画面下端で切れたリンク 213x6・Android の地図のカルーセルの端で切れた Switch/Button 13x144。どれも切れた押せる要素 = 真陽性
        XCTAssertEqual(fired, ["and-browser_j1_standings.json: link 清水エスパルス 213x6",
                               "and-maps_transit_results.json: switch 3 種類の移動手段 13x144",
                               "and-maps_transit_results.json: button 3 種類の移動手段 13x144"], fired.joined(separator: "\n"))
    }
}
