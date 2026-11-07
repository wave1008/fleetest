import XCTest
@testable import FTCore

/// Android のブリッジが押せると申告した覆い(`clickable`)は、型が staticText でも押せる覆いとして扱う。
/// 36周目 amax F1: 全開のシートの裏の行 #row_main_05 への tap が、手前のキューの行 #queue_row_14(setOnClickListener を付けた TextView =
/// 木では staticText)を押して ✅(12/12)。申告の無い staticText の覆い(行の文字・装飾)は従来どおり中心を撃つ側
final class AndroidClickableCoverTests: XCTestCase {
    private let screen = FTRect(x: 0, y: 0, width: 1280, height: 2856)

    private func tree(coverClickable: Bool?) -> (ElementInfo, [ElementInfo]) {
        let mainList = ElementInfo(ref: 1, type: "collectionView", identifier: "list_main", label: nil, value: nil, placeholder: nil,
                                   enabled: true, frame: FTRect(x: 0, y: 200, width: 1280, height: 2400), depth: 1,
                                   scrollable: true, z: 1)
        let target = ElementInfo(ref: 2, type: "staticText", identifier: "row_main_05", label: "本文 05", value: nil, placeholder: nil,
                                 enabled: true, frame: FTRect(x: 0, y: 1326, width: 1280, height: 168), depth: 2, z: 2,
                                 clickable: true)
        let sheet = ElementInfo(ref: 3, type: "other", identifier: "player_sheet", label: nil, value: nil, placeholder: nil,
                                enabled: true, frame: FTRect(x: 0, y: 486, width: 1280, height: 2298), depth: 1, z: 3)
        let cover = ElementInfo(ref: 4, type: "staticText", identifier: "queue_row_14", label: "キュー 14", value: nil, placeholder: nil,
                                enabled: true, frame: FTRect(x: 0, y: 1261, width: 1280, height: 300), depth: 2, z: 4,
                                clickable: coverClickable)
        return (target, [mainList, target, sheet, cover])
    }

    func testAClickableStaticTextCoverIsTreatedAsPressable() {
        let (target, elements) = tree(coverClickable: true)
        let verdict = TapTargetGeometry.coveredTouch(for: target, in: elements, screen: screen, inferring: true, scale: 3,
                                                     zIsPaintOrder: true)
        guard case .tooThin(_, _, let over)? = verdict else { return XCTFail("押せる覆いとして扱っていない: \(String(describing: verdict))") }
        XCTAssertEqual(over.identifier, "queue_row_14")
    }

    func testAStaticTextCoverWithoutTheClaimKeepsShootingTheCentre() {
        let (target, elements) = tree(coverClickable: nil)
        XCTAssertNil(TapTargetGeometry.coveredTouch(for: target, in: elements, screen: screen, inferring: true, scale: 3,
                                                    zIsPaintOrder: true))
    }

    func testTheClaimSurvivesDecoding() throws {
        let json = #"{"ref":1,"type":"StaticText","enabled":true,"frame":{"x":0,"y":0,"width":1,"height":1},"depth":0,"clickable":true}"#
        let element = try JSONDecoder().decode(ElementInfo.self, from: Data(json.utf8))
        XCTAssertEqual(element.clickable, true)
        let absent = try JSONDecoder().decode(ElementInfo.self, from: Data(#"{"ref":1,"type":"StaticText","enabled":true,"frame":{"x":0,"y":0,"width":1,"height":1},"depth":0}"#.utf8))
        XCTAssertNil(absent.clickable)
    }
}
