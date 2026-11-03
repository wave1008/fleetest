// 操作可能な帯(タブ列)に中心を覆われた対象の「覆われていない見えている部分」の判定の固定。
import XCTest
@testable import FTCore

final class CoveredTouchPartTests: XCTestCase {
    private let screen = FTRect(x: 0, y: 0, width: 1080, height: 2400)

    private func el(_ ref: Int, _ type: String, id: String, _ r: FTRect) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: id, value: nil,
                    placeholder: nil, enabled: true, frame: r, depth: 2)
    }

    /// 下のタブ列が対象の下側(中心を含む)を覆う。タブ列は木で対象より後ろ = 手前
    private func tree(targetHeight: Double, tabTop: Double) -> (ElementInfo, [ElementInfo]) {
        let target = el(1, "button", id: "btn_input_submit", FTRect(x: 100, y: 2000, width: 800, height: targetHeight))
        let tab = el(2, "button", id: "tab_home", FTRect(x: 0, y: tabTop, width: 1080, height: 2400 - tabTop))
        return (target, [target, tab])
    }

    func testVisiblePartAboveTheTabBarIsPressedWhenItReachesTheFloor() {
        let (target, elements) = tree(targetHeight: 200, tabTop: 2080)   // 上の 80px が見える(中心 2100 は覆われる)
        guard case .visiblePart(let rect, let over)? = TapTargetGeometry.coveredTouch(
            for: target, in: elements, screen: screen, inferring: true, scale: 3) else {
            return XCTFail("見えている部分があれば押す")
        }
        XCTAssertEqual(over.identifier, "tab_home")
        XCTAssertEqual(rect.y, 2000)
        XCTAssertEqual(rect.height, 80)
        XCTAssertLessThan(rect.centerY, 2080, "押す点は覆いの外")
    }

    func testThinRemainderBelowTheFloorIsRefused() {
        let (target, elements) = tree(targetHeight: 200, tabTop: 2010)   // 残り 10px < 8*3
        guard case .tooThin(let visible, let floor, let over)? = TapTargetGeometry.coveredTouch(
            for: target, in: elements, screen: screen, inferring: true, scale: 3) else {
            return XCTFail("床に届かなければ撃たない")
        }
        XCTAssertEqual(visible, 10)
        XCTAssertEqual(floor, 24)
        XCTAssertEqual(over.identifier, "tab_home")
    }

    func testFloorScalesWithTheTreeUnit() {
        let (target, elements) = tree(targetHeight: 200, tabTop: 2010)   // 残り 10: scale 1 なら床 8 以上
        guard case .visiblePart? = TapTargetGeometry.coveredTouch(
            for: target, in: elements, screen: screen, inferring: true, scale: 1) else {
            return XCTFail("scale 1 なら床 8 を超える")
        }
    }

    /// 実測の木(Flutter の横向き・2856x1280): 欄の中心を覆う #tab_controls だけを引くと、左右の片(各 95,424)が上の帯(83,328)
    /// より広く、左の片 = #tab_home の下を押してホームへ遷移した。手前のタブを全部引けば、残るのは上の帯だけ
    func testSiblingTabsAreSubtractedToo() {
        let wide = FTRect(x: 0, y: 0, width: 2856, height: 1280)
        let field = el(1, "textField", id: "field_password", FTRect(x: 204, y: 1032, width: 2604, height: 144))
        let home = el(2, "button", id: "tab_home", FTRect(x: 156, y: 1064, width: 900, height: 144))
        let controls = el(3, "button", id: "tab_controls", FTRect(x: 1056, y: 1064, width: 900, height: 144))
        let about = el(4, "button", id: "tab_about", FTRect(x: 1956, y: 1064, width: 900, height: 144))
        guard case .visiblePart(let rect, let over)? = TapTargetGeometry.coveredTouch(
            for: field, in: [field, home, controls, about], screen: wide, inferring: true, scale: 3) else {
            return XCTFail("上の帯 32px は床 24 以上")
        }
        XCTAssertEqual(over.identifier, "tab_controls")
        XCTAssertEqual(rect, FTRect(x: 204, y: 1032, width: 2604, height: 32))
        for tab in [home, controls, about] {
            XCTAssertFalse(tab.frame.y <= rect.centerY && rect.centerY <= tab.frame.y + tab.frame.height,
                           "押す点が \(tab.identifier ?? "") の下")
        }
    }

    /// 対象を丸ごと包む手前の相手(ラッパー。ref が対象とタブの間 = 対象より手前・タブより奥)は引かない
    /// (引くと残りが無くなり、押せる対象を断る)
    func testEnclosingWrapperIsNotSubtracted() {
        let target = el(1, "button", id: "btn_input_submit", FTRect(x: 100, y: 2000, width: 800, height: 200))
        let wrapper = el(2, "clickable", id: "wrapper", FTRect(x: 0, y: 1900, width: 1080, height: 500))
        let tab = el(3, "button", id: "tab_home", FTRect(x: 0, y: 2080, width: 1080, height: 320))
        guard case .visiblePart(let rect, let over)? = TapTargetGeometry.coveredTouch(
            for: target, in: [target, wrapper, tab], screen: screen, inferring: true, scale: 3) else {
            return XCTFail("包む相手は覆いではない")
        }
        XCTAssertEqual(over.identifier, "tab_home")
        XCTAssertEqual(rect.height, 80)
    }

    /// 回帰の実測(E2EX-iOS の FAB 画面): FAB が木で一覧より前に並ぶので、一覧の行が手前と読まれる。覆いが対象の祖先でない
    /// スクロール容器の中身なら塗り順は推測でしかないので、断らずに従来の扱い(nil)へ戻す(行は押せる型 = ⓪では外れない形)
    func testScrollContentOverAFloatingButtonIsLeftToTheOldPath() {
        let phone = FTRect(x: 0, y: 0, width: 402, height: 874)
        let fab = ElementInfo(ref: 3, type: "button", identifier: "fab_add", label: "追加", value: nil, placeholder: nil,
                              enabled: true, frame: FTRect(x: 332, y: 719, width: 50, height: 48), depth: 1)
        let list = ElementInfo(ref: 4, type: "other", identifier: nil, label: nil, value: nil, placeholder: nil,
                               enabled: true, frame: phone, depth: 1, scrollable: true)
        let row = ElementInfo(ref: 28, type: "cell", identifier: "row_f_11", label: "行 F11", value: nil, placeholder: nil,
                              enabled: true, frame: FTRect(x: 16, y: 726, width: 370, height: 52), depth: 2)
        let elements = [fab, list, row]
        XCTAssertEqual(TapTargetGeometry.overlayCoveringForUncover(fab, in: elements, screen: phone)?.ref, 28,
                       "前提: 既存の判定は行を覆いと読む")
        XCTAssertNil(TapTargetGeometry.coveredTouch(for: fab, in: elements, screen: phone, inferring: true, scale: 1))
    }

    /// 回帰の実測(E2EY-iOS の OTP): 押せる型でない箱の上に透明な入力欄が重なる。押す相手は手前の欄なので、従来の扱い(nil)へ戻す
    func testNonOperableTargetUnderAnInputIsLeftToTheOldPath() {
        let phone = FTRect(x: 0, y: 0, width: 402, height: 874)
        let box = ElementInfo(ref: 7, type: "other", identifier: "otp_box_3", label: "OTP 3", value: nil, placeholder: nil,
                              enabled: true, frame: FTRect(x: 152, y: 198, width: 45, height: 53), depth: 2)
        let field = ElementInfo(ref: 11, type: "textField", identifier: "field_otp", label: nil, value: nil, placeholder: nil,
                                enabled: true, frame: FTRect(x: 16, y: 214, width: 370, height: 22), depth: 2)
        XCTAssertEqual(TapTargetGeometry.overlayCoveringForUncover(box, in: [box, field], screen: phone)?.ref, 11,
                       "前提: 既存の判定は欄を覆いと読む")
        XCTAssertNil(TapTargetGeometry.coveredTouch(for: box, in: [box, field], screen: phone, inferring: true, scale: 1))
    }

    /// 押せない覆い(見出しの容器が中の文字を覆うと読む = 塗り順の推測違い)は従来の扱い(nil)。中心を撃っても別の部品は押さない
    func testNonOperableCoverIsLeftToTheOldPath() {
        // MCPRefGuardTests.testPartialCoverageContainerBelowThresholdOccludes と同じ木
        let title = ElementInfo(ref: 1, type: "button", identifier: "transit_station_title_name", label: "東京駅", value: nil,
                                placeholder: nil, enabled: true, frame: FTRect(x: 285, y: 0, width: 510, height: 85), depth: 1)
        let header = ElementInfo(ref: 2, type: "other", identifier: "header_container", label: nil, value: nil,
                                 placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 0, width: 1080, height: 290), depth: 1)
        let back = ElementInfo(ref: 3, type: "button", identifier: "btn_back", label: "戻る", value: nil,
                               placeholder: nil, enabled: true, frame: FTRect(x: 20, y: 20, width: 60, height: 60), depth: 2)
        let tree = [title, header, back]
        XCTAssertEqual(TapTargetGeometry.overlayCoveringForUncover(title, in: tree, screen: screen)?.ref, 2,
                       "前提: 既存の判定は容器を覆いと読む")
        XCTAssertNil(TapTargetGeometry.coveredTouch(for: title, in: tree, screen: screen, inferring: true, scale: 3))
    }

    /// 押せない手前の要素(対象の上端に重なる装飾の文字)は引かない: 引くと見えている帯が床を割って押せる対象を断る
    func testNonOperableOverlayIsNotSubtracted() {
        let (target, base) = tree(targetHeight: 200, tabTop: 2080)    // 上の 80px が見える
        let badge = el(3, "staticText", id: "badge", FTRect(x: 100, y: 1990, width: 800, height: 70))   // 上端の 60px に重なる
        guard case .visiblePart(let rect, _)? = TapTargetGeometry.coveredTouch(
            for: target, in: base + [badge], screen: screen, inferring: true, scale: 3) else {
            return XCTFail("押せない装飾は覆いに数えない")
        }
        XCTAssertEqual(rect.height, 80)
    }

    /// 最前面がタブの中の文字(押せない型)でも、押されるのはそのタブ = 押せる祖先を覆いとして扱う(中心を撃つ従来の扱いに戻さない)
    func testTextInsideATabCountsAsTheTab() {
        let target = ElementInfo(ref: 1, type: "button", identifier: "btn_submit", label: "送信", value: nil, placeholder: nil,
                                 enabled: true, frame: FTRect(x: 100, y: 2000, width: 800, height: 200), depth: 1)
        let tab = ElementInfo(ref: 2, type: "clickable", identifier: "tab_home", label: nil, value: nil, placeholder: nil,
                              enabled: true, frame: FTRect(x: 0, y: 2080, width: 1080, height: 320), depth: 1)
        let label = ElementInfo(ref: 3, type: "staticText", identifier: nil, label: "ホーム", value: nil, placeholder: nil,
                                enabled: true, frame: FTRect(x: 0, y: 2080, width: 1080, height: 320), depth: 2)
        let tree = [target, tab, label]
        XCTAssertEqual(TapTargetGeometry.overlayCoveringForUncover(target, in: tree, screen: screen)?.ref, 3,
                       "前提: 最前面はタブの中の文字")
        guard case .visiblePart(let rect, let over)? = TapTargetGeometry.coveredTouch(
            for: target, in: tree, screen: screen, inferring: true, scale: 3) else {
            return XCTFail("タブの中の文字の下でも見えている部分を押す")
        }
        XCTAssertEqual(over.identifier, "tab_home")
        XCTAssertEqual(rect.height, 80)
    }

    func testUncoveredTargetIsNil() {
        let target = el(1, "button", id: "btn", FTRect(x: 100, y: 1000, width: 800, height: 100))
        let tab = el(2, "button", id: "tab_home", FTRect(x: 0, y: 2200, width: 1080, height: 200))
        XCTAssertNil(TapTargetGeometry.coveredTouch(for: target, in: [target, tab], screen: screen,
                                                    inferring: true, scale: 3))
    }
}

/// 指で触る操作の撃つ段が、覆われた対象の見えている部分の判定(`coveredTouchPlan`)を通ること(兄弟の取りこぼしを落とす)。
/// 打鍵・消去は欄の ref に撃つので通らない(`settleCoverAfterKeyboardClose(allowsVisiblePart: false)`)
final class CoveredTouchPlanWiringTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/FTCore/\(name)"), encoding: .utf8)
    }

    func testEveryFingerTouchFireSiteConsultsThePlan() throws {
        let actions = try source("StepExecutor+Actions.swift")
        // tap(押すだけ)・長押し・doubleTap・swipeElementToElement の始点
        XCTAssertGreaterThanOrEqual(actions.components(separatedBy: "coveredTouchPlan(element").count - 1, 4)
        XCTAssertTrue(try source("StepExecutor+Hold.swift").contains("coveredTouchPlan(element"), "holdStart")
    }

    func testTypeAndClearRefuseInsteadOfPressingAPart() throws {
        let actions = try source("StepExecutor+Actions.swift")
        XCTAssertTrue(actions.contains("verb: \"typing\", relift: relitAfterClose, allowsVisiblePart: false"))
        XCTAssertTrue(actions.contains("verb: \"clearing\", relift: relitAfterClose, allowsVisiblePart: false"))
    }
}
