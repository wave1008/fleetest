// scroll(ft_swipe の scrollFrame・DSL の scrollUp(scrollFrame:) 等)の「動かなかった」の注記。witness: Apple マップの場所カード
// (半開き)の中を払っても動かず(送りの 188pt ではシートが戻る)、枠の外の地図のピンが1つ消えたので注記も出なかった

import XCTest
@testable import FTCore

final class ScrollHalfOpenSheetNoteTests: XCTestCase {

    private func el(_ ref: Int, _ type: String, id: String?, label: String? = nil, y: Double, height: Double,
                    depth: Int, scrollable: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: y, width: 400, height: height), depth: depth, scrollable: scrollable)
    }

    /// 偽ドライバの画面(400x800)。`sheetTop`〜`bottom` が場所カード。読みごとに枠の外の地図のピンの有無だけが入れ替わる
    private func screens(sheetTop: Double, bottom: Double) -> [[ElementInfo]] {
        (0..<12).map { read in
            var elements = [el(1, "other", id: "map", y: 0, height: 800, depth: 0)]
            if read % 2 == 0 { elements.append(el(2, "other", id: "VKPointFeature", label: "大阪城", y: 100, height: 30, depth: 1)) }
            elements += [
                ElementInfo(ref: 3, type: "button", identifier: "Card grabber", label: "カードコントローラ", value: nil,
                            placeholder: nil, enabled: true, frame: FTRect(x: 150, y: sheetTop - 5, width: 100, height: 20),
                            depth: 1),
                el(4, "scrollView", id: "card", y: sheetTop, height: bottom - sheetTop, depth: 1, scrollable: true),
                el(5, "staticText", id: "title", label: "大阪城", y: sheetTop + 20, height: 30, depth: 2),
            ]
            return elements
        }
    }

    private func note(sheetTop: Double, bottom: Double = 800, scrollFrame: Bool) async -> String? {
        var step = FlowStep(action: "scroll", direction: "up", maxSwipes: 1)
        if scrollFrame { step.scrollFrame = FlowLocator(id: "card") }
        let driver = FakeAppDriver(name: "d", log: CallLog(), snapshotElements: screens(sheetTop: sheetTop, bottom: bottom))
        let outcome = await StepExecutor(driver: driver, releasesScrollTouch: true, isAndroid: false, tunables: RunTunables(),
                                         uiFramework: .uikit).execute(step)
        guard case .passed = outcome.status else { XCTFail("\(outcome.status)"); return nil }
        return outcome.driverFallback
    }

    func testAHalfOpenSheetThatDidNotMoveNamesItsGrabber() async {
        let text = await note(sheetTop: 480, scrollFrame: true) ?? ""
        XCTAssertTrue(text.contains("it is a half-open sheet"), text)
        XCTAssertTrue(text.contains("Card grabber"), text)
    }

    func testAChangeOutsideTheWrittenFrameDoesNotHideThatNothingMoved() async {
        // 下端が画面の下に接しない容器(シートではない)。地図のピンは枠の外
        let text = await note(sheetTop: 150, bottom: 650, scrollFrame: true) ?? ""
        XCTAssertTrue(text.contains(StepNote.scrollMovedNothingInWrittenFrameText), text)
    }

    func testWithoutAScrollFrameTheWholeTreeIsStillCompared() async {
        // 画面中央を含む容器(枠なしの探索が比べる領域になりうる形)でも、枠を書いていない scroll は木全体で比べる
        let text = await note(sheetTop: 150, bottom: 650, scrollFrame: false) ?? ""
        XCTAssertFalse(text.contains("nothing on the screen moved") || text.contains("half-open sheet"), text)
    }
}
