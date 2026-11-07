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

/// 貼り付く見出しの判定(`pinnedBandCovering`)も、押せると申告した行を見出しにしない(37周目 amax F2: 全開のシートで scrollToTop の直後の
/// #queue_row_00 への tap が、キューの容器の上端に揃った裏の本文の行 #row_main_02 を見出しと読んで送り、何も押さずに ✅・8/8)
final class AndroidClickablePinnedBandTests: XCTestCase {
    func testAClickableRowAlignedToTheContainerEdgeIsNotAPinnedHeader() {
        let container = FTRect(x: 0, y: 822, width: 1280, height: 1962)
        let list = ElementInfo(ref: 1, type: "collectionView", identifier: "list_queue", label: nil, value: nil, placeholder: nil,
                               enabled: true, frame: container, depth: 1, scrollable: true, z: 38)
        let target = ElementInfo(ref: 2, type: "staticText", identifier: "queue_row_00", label: "キュー 00", value: nil, placeholder: nil,
                                 enabled: true, frame: FTRect(x: 0, y: 822, width: 1280, height: 168), depth: 2, z: 39, clickable: true)
        var behind = ElementInfo(ref: 3, type: "staticText", identifier: "row_main_02", label: "本文 02", value: nil, placeholder: nil,
                                 enabled: true, frame: FTRect(x: 0, y: 822, width: 1280, height: 168), depth: 1, z: 19, clickable: true)
        XCTAssertNil(TapTargetGeometry.pinnedBandCovering(target, in: [list, target, behind], container: container))
        behind.clickable = nil
        XCTAssertNotNil(TapTargetGeometry.pinnedBandCovering(target, in: [list, target, behind], container: container),
                        "申告の無い文字の帯は従来どおり見出しとして扱う(この対照が崩れたらテストの前提が違う)")
    }
}
