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

/// 同じ枠で手前に描かれた押せる別の要素も覆いとして扱う(OI-195 ①: 全開になったシートのキューの行 #queue_row_08 が裏の本文の行
/// #row_main_10 と同じ枠 (0,2166 1280x168) に並び、最前面の判定が同じ枠の相手を外して容器 #list_queue を名指し、中心を撃って
/// キューの行を押して ✅・12/12)。木は 11/8 に E2EY-Android で取った撃つ直前の木から関係する要素だけを写した
final class AndroidSameFrameCoverTests: XCTestCase {
    private let screen = FTRect(x: 0, y: 0, width: 1280, height: 2856)

    private func tree(targetType: String = "staticText") -> (ElementInfo, [ElementInfo]) {
        let sheet = ElementInfo(ref: 6, type: "other", identifier: "player_sheet", label: nil, value: nil, placeholder: nil,
                                enabled: true, frame: FTRect(x: 0, y: 486, width: 1280, height: 2298), depth: 12, z: 31)
        let queue = ElementInfo(ref: 12, type: "collectionView", identifier: "list_queue", label: nil, value: nil, placeholder: nil,
                                enabled: true, frame: FTRect(x: 0, y: 822, width: 1280, height: 1962), depth: 13,
                                scrollable: true, z: 38)
        let queueRow = ElementInfo(ref: 21, type: "staticText", identifier: "queue_row_08", label: "キュー 08", value: nil,
                                   placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 2166, width: 1280, height: 168),
                                   depth: 14, z: 47, clickable: true)
        let main = ElementInfo(ref: 25, type: "collectionView", identifier: "list_main", label: nil, value: nil, placeholder: nil,
                               enabled: true, frame: FTRect(x: 0, y: 486, width: 1280, height: 2298), depth: 12,
                               scrollable: true, z: 16)
        let target = ElementInfo(ref: 36, type: targetType, identifier: "row_main_10", label: "本文 10", value: nil,
                                 placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 2166, width: 1280, height: 168),
                                 depth: 13, z: 27, clickable: true)
        return (target, [sheet, queue, queueRow, main, target])
    }

    func testASameFramePressableRowInFrontIsTheCover() {
        let (target, elements) = tree()
        let verdict = TapTargetGeometry.coveredTouch(for: target, in: elements, screen: screen, inferring: true, scale: 3,
                                                     zIsPaintOrder: true)
        guard case .tooThin(_, _, let over)? = verdict else { return XCTFail("同じ枠の手前の行を覆いと見ていない: \(String(describing: verdict))") }
        XCTAssertEqual(over.identifier, "queue_row_08")
    }

    /// 覆いが別の一覧の中に無い形で確かめる(一覧の中なら塗り順が無いときは後段の例外②でも外れ、門の有無が分からない)
    func testWithoutPaintOrderTheSameFrameRowIsNotGuessed() {
        let (target, full) = tree()
        let elements = full.filter { $0.identifier != "list_queue" }.map { e -> ElementInfo in
            var e = e
            if e.identifier == "queue_row_08" { e.depth = 13 }
            return e
        }
        XCTAssertNotNil(TapTargetGeometry.coveredTouch(for: target, in: elements, screen: screen, inferring: true, scale: 3,
                                                       zIsPaintOrder: true), "この形の前提(塗り順があれば覆い)が崩れている")
        XCTAssertNil(TapTargetGeometry.coveredTouch(for: target, in: elements, screen: screen, inferring: true, scale: 3,
                                                    zIsPaintOrder: false))
    }

    /// 入力欄は外す(同じ枠の手前の受け手がタッチを欄へ渡す作り。コーパスの E2E-Android の #field_wrapped)
    func testATextInputUnderASameFramePressableIsStillShot() {
        let (target, elements) = tree(targetType: "textField")
        XCTAssertNil(TapTargetGeometry.coveredTouch(for: target, in: elements, screen: screen, inferring: true, scale: 3,
                                                    zIsPaintOrder: true))
    }
}
