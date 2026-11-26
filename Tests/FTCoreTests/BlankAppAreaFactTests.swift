// テキストの可視性検証の失敗文に「アプリ領域全体が一色」の事実を添える。判定(赤)は変えない。添えないと、1つの要素が
// 隠れているのか画面全体に何も描かれていないのかを読み分けられない

import XCTest
@testable import FTCore

final class BlankAppAreaFactTests: XCTestCase {

    private static let frames = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/BlackFrames")

    /// 実物: XCUITest の run で CMP の画面が真っ白に撮れた絵(ステータスバーだけ残る)
    func testWhiteAppAreaWithOnlyTheStatusBarIsNamed() throws {
        let png = try Data(contentsOf: Self.frames.appendingPathComponent("ios-xcuitest-white-app-with-status-bar.png"))
        // その回の木のいちばん上の要素(#btn_back)は y=78pt。ステータスバー(62pt)はそれより上
        let back = ElementInfo(ref: 2, type: "button", identifier: "btn_back", label: "戻る", value: nil, placeholder: nil,
                               enabled: true, frame: FTRect(x: 16, y: 78, width: 76, height: 48), depth: 1)
        let fact = StepExecutor.blankAppAreaFact(screenshot: png, elements: [back], screen: Self.screen, keyboard: nil)
        XCTAssertTrue(fact.contains("single colour"), fact)
    }

    /// 上端近く(ステータスバーの直下)にだけ描かれた中身は、木に載るので帯を広げない = 一色と言わない
    func testContentRightBelowTheStatusBarIsNotHiddenByTheBand() throws {
        let png = try Data(contentsOf: Self.frames.appendingPathComponent("ios-xcuitest-white-app-with-status-bar.png"))
        let clock = ElementInfo(ref: 3, type: "staticText", identifier: nil, label: "22:48", value: nil, placeholder: nil,
                                enabled: true, frame: FTRect(x: 40, y: 14, width: 60, height: 22), depth: 1)
        XCTAssertEqual(StepExecutor.blankAppAreaFact(screenshot: png, elements: [clock], screen: Self.screen, keyboard: nil), "",
                       "木のいちばん上が時計の位置なら、時計の行は除かれずに一色でないと読む")
    }

    private static let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    /// 実物: Android の Emulator でアプリの面が真っ黒・キーボードだけ描かれた絵。キーボードの枠より上だけを見れば一色
    /// (白紙の公表 `RenderCollapse.judge` もキーボードを除いて見る = 失敗文の事実と公表を食い違わせない)
    func testBlackAppAreaWithOnlyTheKeyboardDrawnIsNamedWhenTheKeyboardIsDeclared() throws {
        let png = try Data(contentsOf: Self.frames.appendingPathComponent("android-black-app-with-keyboard.png"))
        let screen = FTRect(x: 0, y: 0, width: 1280, height: 2856)
        let back = ElementInfo(ref: 1, type: "button", identifier: "btn_back", label: "戻る", value: nil, placeholder: nil,
                               enabled: true, frame: FTRect(x: 36, y: 192, width: 264, height: 144), depth: 1)
        let keyboard = FTRect(x: 0, y: 1745, width: 1280, height: 1111)
        XCTAssertTrue(StepExecutor.blankAppAreaFact(screenshot: png, elements: [back], screen: screen, keyboard: keyboard)
            .contains("single colour"))
        XCTAssertEqual(StepExecutor.blankAppAreaFact(screenshot: png, elements: [back], screen: screen, keyboard: nil), "",
                       "キーボードの申告が無ければ今までどおり画面の下端まで見る")
        XCTAssertEqual(StepExecutor.blankAppAreaFact(screenshot: png, elements: [back], screen: screen,
                                                     keyboard: FTRect(x: 0, y: 2856, width: 1280, height: 1111)), "",
                       "画面の外へ下がったキーボードは出ていない")
    }

    /// 中身のある絵(一部だけ黒い WebView)には、キーボードが出ていても添えない
    func testAScreenWithContentAboveTheKeyboardGetsNoFact() throws {
        let png = try Data(contentsOf: Self.frames.appendingPathComponent("ios-partly-black-webview.png"))
        XCTAssertEqual(StepExecutor.blankAppAreaFact(screenshot: png, elements: [], screen: Self.screen,
                                                     keyboard: FTRect(x: 0, y: 600, width: 402, height: 274)), "")
    }

    /// 中身のある絵(一部だけ黒い WebView)には添えない
    func testAScreenWithContentGetsNoFact() throws {
        let png = try Data(contentsOf: Self.frames.appendingPathComponent("ios-partly-black-webview.png"))
        XCTAssertEqual(StepExecutor.blankAppAreaFact(screenshot: png, elements: [], screen: Self.screen, keyboard: nil), "")
    }
}
