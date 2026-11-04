import XCTest
@testable import FTCore

/// occlusion-guard の Tier-0 幾何ヒューリスティック(FM/スクショ非依存)の検証。
/// 特に F 修正: Compose-iOS の frame クランプで画面端に潰れた ghost スタックを occluder から除外する。
final class OcclusionSuspicionTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 400, height: 800)

    private func el(_ ref: Int, _ frame: FTRect) -> ElementInfo {
        ElementInfo(ref: ref, type: "staticText", identifier: nil, label: "x", value: nil,
                    placeholder: nil, enabled: true, frame: frame, depth: 0)
    }

    /// 画面端に潰れた同一 frame の ghost スタック(3枚)は occluder とみなさない → 疑い無し(false)。
    func testClampGhostStackIsNotOcclusion() {
        let target = el(1, FTRect(x: 0, y: 750, width: 400, height: 40))   // 見えている最下段の行
        let ghost = FTRect(x: 0, y: 760, width: 400, height: 40)           // 画面端(y+h=800)に潰れた行
        let elements = [target, el(2, ghost), el(3, ghost), el(4, ghost)]  // 同一 frame ×3 = スタック
        XCTAssertFalse(OcclusionSuspicion.geometric(
            element: target, in: elements, screen: screen, looseMatch: false),
            "クランプ ghost スタックで偽の occlusion 疑いを立てないこと")
    }

    /// 本物の単独オーバーレイ(ユニーク frame)が重なれば従来どおり疑う(true)。検出力は維持。
    func testGenuineSingleOverlayIsOcclusion() {
        let target = el(1, FTRect(x: 0, y: 750, width: 400, height: 40))
        let overlay = el(2, FTRect(x: 0, y: 760, width: 400, height: 40))   // 重複なし
        XCTAssertTrue(OcclusionSuspicion.geometric(
            element: target, in: [target, overlay], screen: screen, looseMatch: false),
            "本物の単独オーバーレイは占有率 >= 0.4 で疑うこと")
    }

    /// 親子で frame を共有するだけの2重複は ghost 扱いしない(本物の occluder を守る・閾値3)。
    func testTwoDuplicateFramesStillOcclusion() {
        let target = el(1, FTRect(x: 0, y: 750, width: 400, height: 40))
        let shared = FTRect(x: 0, y: 760, width: 400, height: 40)
        XCTAssertTrue(OcclusionSuspicion.geometric(
            element: target, in: [target, el(2, shared), el(3, shared)], screen: screen, looseMatch: false),
            "2重複(親子共有)は除外せず疑うこと")
    }

    /// 画面端に接しない同一 frame スタックは(クランプの兆候が無いので)ghost 扱いしない。
    func testDuplicateFramesAwayFromEdgeStillOcclusion() {
        let target = el(1, FTRect(x: 50, y: 300, width: 200, height: 40))
        let mid = FTRect(x: 50, y: 305, width: 200, height: 40)            // 画面中央・端に非接触
        XCTAssertTrue(OcclusionSuspicion.geometric(
            element: target, in: [target, el(2, mid), el(3, mid), el(4, mid)], screen: screen, looseMatch: false),
            "端に接しない重複は clamp ghost ではない")
    }

    /// 部分一致(substring)ロケータは従来どおり無条件で疑う。
    func testLooseMatchAlwaysSuspicious() {
        let target = el(1, FTRect(x: 0, y: 100, width: 100, height: 20))
        XCTAssertTrue(OcclusionSuspicion.geometric(
            element: target, in: [target], screen: screen, looseMatch: true))
    }

    // MARK: - touchesScrollEdge

    private func scrollEdgeFixture(textY: Double, textHeight: Double, scrollable: Bool = true) -> ([ElementInfo], ElementInfo) {
        var pane = ElementInfo(ref: 1, type: "scrollView", identifier: "pane", label: nil, value: nil,
                               placeholder: nil, enabled: true,
                               frame: FTRect(x: 0, y: 100, width: 400, height: 300), depth: 0)
        pane.scrollable = scrollable
        let text = ElementInfo(ref: 2, type: "staticText", identifier: "echo", label: "page=0", value: nil,
                               placeholder: nil, enabled: true,
                               frame: FTRect(x: 10, y: textY, width: 100, height: textHeight), depth: 1)
        return ([pane, text], text)
    }

    func testTextFlushWithTheScrollContainersBottomEdgeIsSuspicious() {
        let (elements, text) = scrollEdgeFixture(textY: 380, textHeight: 20)   // 下端 400 = 容器の下端
        XCTAssertTrue(OcclusionSuspicion.touchesScrollEdge(element: text, in: elements))
    }

    func testTextFlushWithTheScrollContainersTopEdgeIsSuspicious() {
        let (elements, text) = scrollEdgeFixture(textY: 100, textHeight: 20)
        XCTAssertTrue(OcclusionSuspicion.touchesScrollEdge(element: text, in: elements))
    }

    func testTextInsideTheScrollContainerIsNotSuspicious() {
        let (elements, text) = scrollEdgeFixture(textY: 200, textHeight: 20)
        XCTAssertFalse(OcclusionSuspicion.touchesScrollEdge(element: text, in: elements))
    }

    func testEdgeOfANonScrollingContainerIsNotSuspicious() {
        let (elements, text) = scrollEdgeFixture(textY: 380, textHeight: 20, scrollable: false)
        XCTAssertFalse(OcclusionSuspicion.touchesScrollEdge(element: text, in: elements))
    }

    /// F2: 行(clickable・ラベルは子の文字から畳んだもの)が容器の上端に接している —— 文字の型でなくても読ませる
    func testClickableRowFlushWithTheTopEdgeIsSuspicious() {
        var (elements, _) = scrollEdgeFixture(textY: 100, textHeight: 25)
        var row = elements[1]
        row.type = "clickable"
        row.label = "行 01"
        elements[1] = row
        XCTAssertTrue(OcclusionSuspicion.touchesScrollEdge(element: row, in: elements))
    }

    /// F2(iOS): 行の枠は容器の下端を3pt だけ内側にして外へはみ出す(未クリップ)
    func testRowSpillingPastTheBottomEdgeIsSuspicious() {
        var (elements, _) = scrollEdgeFixture(textY: 397, textHeight: 56)
        var row = elements[1]
        row.type = "clickable"
        elements[1] = row
        XCTAssertTrue(OcclusionSuspicion.touchesScrollEdge(element: row, in: elements))
    }

    /// F1(iOS): 容器の上端より外へ送られた見出し(枠が容器の外に丸ごと出ている)
    func testTextEntirelyAboveTheContainerIsSuspicious() {
        let (elements, text) = scrollEdgeFixture(textY: 60, textHeight: 20)
        XCTAssertTrue(OcclusionSuspicion.touchesScrollEdge(element: text, in: elements))
    }

    /// F3(iOS): 容器の下端より外(タブバーの下)に丸ごと潜ったボタンは MCP の scroll-leftover と同じ判定で拾う
    func testButtonUnderTheTabBarIsScrollLeftover() {
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        func el(_ ref: Int, _ type: String, _ depth: Int, _ f: FTRect, scroll: Bool = false) -> ElementInfo {
            var e = ElementInfo(ref: ref, type: type, identifier: nil, label: "e\(ref)", value: nil,
                                placeholder: nil, enabled: true, frame: f, depth: depth)
            if scroll { e.scrollable = true }
            return e
        }
        let elements = [
            el(1, "scrollView", 0, FTRect(x: 0, y: 114, width: 402, height: 663), scroll: true),
            el(2, "button", 1, FTRect(x: 16, y: 200, width: 370, height: 50)),
            el(3, "button", 1, FTRect(x: 16, y: 300, width: 370, height: 50)),
            el(4, "button", 1, FTRect(x: 16, y: 788, width: 370, height: 62)),
            el(5, "tabBar", 0, FTRect(x: 0, y: 778, width: 402, height: 96)),
        ]
        XCTAssertTrue(OcclusionSuspicion.isScrollLeftover(element: elements[3], in: elements, screen: screen))
        XCTAssertTrue(OcclusionSuspicion.touchesScrollEdge(element: elements[3], in: elements))
        XCTAssertFalse(OcclusionSuspicion.isScrollLeftover(element: elements[1], in: elements, screen: screen))
    }

    /// 中心を何も覆っていない(タブバーが無い)容器の外の行も、容器の外の残り(MCP の scroll-leftover と同じ2つ目の判定)
    func testRowOutsideTheScrollerWithNothingOnItsCentreIsStillScrollLeftover() {
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        func el(_ ref: Int, _ type: String, _ depth: Int, _ f: FTRect, scroll: Bool = false) -> ElementInfo {
            var e = ElementInfo(ref: ref, type: type, identifier: nil, label: "e\(ref)", value: nil,
                                placeholder: nil, enabled: true, frame: f, depth: depth)
            if scroll { e.scrollable = true }
            return e
        }
        let elements = [
            el(1, "scrollView", 0, FTRect(x: 0, y: 114, width: 402, height: 663), scroll: true),
            el(2, "button", 1, FTRect(x: 16, y: 200, width: 370, height: 50)),
            el(3, "button", 1, FTRect(x: 16, y: 300, width: 370, height: 50)),
            el(4, "button", 1, FTRect(x: 16, y: 788, width: 370, height: 62)),
        ]
        XCTAssertFalse(OcclusionGeometry.isUntappableGhost(elements[3], in: elements, screen: screen),
                       "前提: 中心を覆う物が無い(1つ目の判定では拾えない形)")
        XCTAssertTrue(OcclusionSuspicion.isScrollLeftover(element: elements[3], in: elements, screen: screen))
    }

    // MARK: - covering(誰が覆っているか)

    /// 失敗メッセージ用。**どの要素が覆っているか**まで返す(geometric は真偽だけ)
    func testCoveringReturnsTheOverlappingElement() {
        let target = el(1, FTRect(x: 0, y: 100, width: 400, height: 40))
        let overlay = el(2, FTRect(x: 0, y: 90, width: 400, height: 200))
        XCTAssertEqual(
            OcclusionSuspicion.covering(element: target, in: [target, overlay], screen: screen)?.ref, 2)
    }

    /// 重なりが閾値未満なら覆っていない扱い(geometric の判定と同じ規則を共有する)
    func testCoveringIgnoresSmallOverlap() {
        let target = el(1, FTRect(x: 0, y: 100, width: 400, height: 40))
        let grazing = el(2, FTRect(x: 0, y: 135, width: 400, height: 40))   // 5/40 = 0.125
        XCTAssertNil(OcclusionSuspicion.covering(element: target, in: [target, grazing], screen: screen))
    }

    /// 記載順で**前**にある要素は奥にいるとみなす(手前寄りだけを occluder にする)
    func testCoveringIgnoresElementsBehindTheTarget() {
        let behind = el(1, FTRect(x: 0, y: 90, width: 400, height: 200))
        let target = el(2, FTRect(x: 0, y: 100, width: 400, height: 40))
        XCTAssertNil(OcclusionSuspicion.covering(element: target, in: [behind, target], screen: screen))
    }

    /// クランプ ghost は飛ばし、本物の occluder を返す(geometric と同じ除外規則)
    func testCoveringSkipsClampGhostAndReturnsGenuineOne() {
        let target = el(1, FTRect(x: 0, y: 750, width: 400, height: 40))
        let ghost = FTRect(x: 0, y: 760, width: 400, height: 40)
        let genuine = el(5, FTRect(x: 0, y: 740, width: 400, height: 60))
        let elements = [target, el(2, ghost), el(3, ghost), el(4, ghost), genuine]
        XCTAssertEqual(
            OcclusionSuspicion.covering(element: target, in: elements, screen: screen)?.ref, 5)
    }

    /// 一覧の容器の上へはみ出して切り取られた行は、固定領域の echo を覆わない(描かれていない部分で重なっているだけ)。
    /// 実測(E2EY-CMP・RN の隠れるバー): echo (16,134) の失敗文に「covered by #row_h_42 (0,118)」= 一覧は y=192 から
    func testRowClippedByItsListDoesNotCoverAFixedEcho() {
        let echo = ElementInfo(ref: 1, type: "staticText", identifier: "txt_hide_result", label: "hide=row_h_33", value: nil,
                               placeholder: nil, enabled: true, frame: FTRect(x: 16, y: 134, width: 122, height: 24), depth: 1)
        var list = ElementInfo(ref: 2, type: "other", identifier: nil, label: nil, value: nil, placeholder: nil,
                               enabled: true, frame: FTRect(x: 0, y: 192, width: 400, height: 600), depth: 1)
        list.scrollable = true
        func row(_ ref: Int, _ id: String, y: Double) -> ElementInfo {
            ElementInfo(ref: ref, type: "button", identifier: id, label: nil, value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 0, y: y, width: 400, height: 56), depth: 2)
        }
        let elements = [echo, list, row(3, "row_h_42", y: 118), row(4, "row_h_43", y: 174), row(5, "row_h_44", y: 230)]
        XCTAssertNil(OcclusionSuspicion.covering(element: echo, in: elements, screen: screen))
        // 対照: 容器の中で重なる本物の覆いは名指しする
        var sheet = ElementInfo(ref: 6, type: "button", identifier: "sheet", label: "シート", value: nil, placeholder: nil,
                                enabled: true, frame: FTRect(x: 0, y: 120, width: 400, height: 60), depth: 1)
        sheet.z = nil
        XCTAssertEqual(OcclusionSuspicion.covering(element: echo, in: elements + [sheet], screen: screen)?.identifier, "sheet")
    }
}
