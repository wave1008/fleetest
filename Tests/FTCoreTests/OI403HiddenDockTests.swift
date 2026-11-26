import XCTest
@testable import FTCore

/// Pixel のランチャーは、ドロワーを開いている間も描いていないドック(`hotseat`)とアプリ切替の帯を木に残す。
/// ドックのアイコンの枠に中心が入ったドロワーの行を「覆われている」と読んで押さずに赤にしていた。
/// 木は Emulator -01(Pixel 10 Pro・Android 17)でドロワーを開き切った状態の実物。z はブリッジが View の描画順から振った値で、
/// ドックは z=6〜29・ドロワーの行は z=37〜60・検索欄は z=70
final class OI403HiddenDockTests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/LauncherDrawer/drawer-keeps-hidden-dock.json")

    private func load() throws -> SnapshotResponse {
        try JSONDecoder().decode(SnapshotResponse.self, from: Data(contentsOf: Self.fixture))
    }

    /// ドックの「Chrome」(z=10)の枠に中心が入る「FT E2EX RN」(z=55)は、ドックが奥なので押せる
    func testRowOverTheHiddenDockIsTappable() throws {
        let snap = try load()
        let row = try XCTUnwrap(AppIconLocator.matches("FT E2EX RN", in: snap).first)
        XCTAssertNotNil(OcclusionGeometry.occluder(of: row, in: snap.elements, screen: snap.screen),
                        "前提: 幾何では中心にドックの要素が重なる")
        XCTAssertEqual(AppIconLocator.findTappableIcon("FT E2EX RN", in: snap, isAndroid: true)?.ref, row.ref)
    }

    /// 反例: 検索欄(z=70)の下へ潜った行は今までどおり押さない(手前の覆い = Pixel 3a で観測した検索バーの下の行の形)
    func testRowUnderTheSearchBarIsStillRefused() throws {
        var snap = try load()
        let index = try XCTUnwrap(snap.elements.firstIndex { $0.label == "カメラ" })
        snap.elements[index].frame = FTRect(x: 35, y: 250, width: 303, height: 337)
        XCTAssertNil(AppIconLocator.findTappableIcon("カメラ", in: snap, isAndroid: true))
    }

    /// 申告(renderer)の無い木では z を塗り順と言えないので、今までどおり重なりを覆いに数える
    func testWithoutRendererTheOverlapStillCounts() throws {
        var snap = try load()
        for i in snap.elements.indices { snap.elements[i].renderer = nil }
        XCTAssertNil(AppIconLocator.findTappableIcon("FT E2EX RN", in: snap, isAndroid: true))
    }
}
