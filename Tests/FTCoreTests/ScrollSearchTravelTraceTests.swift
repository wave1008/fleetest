// 探索の失敗文の回ごとの記録に、その回で動いた量と容器の高さを添える(前の回と重なっていたか = 飛び越しの有無を後から読む測る口)。
// witness: Google マップの場所シートで無いものを探して 38 秒(送り5本 + 逆走査5本)。記録が無く、飛び越しがあったかを言えなかった

import XCTest
@testable import FTCore

final class ScrollSearchTravelTraceTests: XCTestCase {

    /// 読むたびに一覧の行が 50 ずつ上へ動く(`shift` = 読みの番号)。`sameIDs` が false なら行は毎回別の id・容器は id 無し(共通要素が無い)
    private func screens(sameIDs: Bool, pinnedHeaders: Int = 0) -> [[ElementInfo]] {
        (0..<30).map { shift in
            var elements = [ElementInfo(ref: 1, type: "collectionView", identifier: sameIDs ? "list" : nil, label: nil, value: nil,
                                        placeholder: nil, enabled: true,
                                        frame: FTRect(x: 0, y: 100, width: 400, height: 300), depth: 0, scrollable: true)]
            for row in 0..<12 {
                let y = 100 + Double(row) * 50 - Double(shift) * 50
                elements.append(ElementInfo(ref: 10 + row, type: "staticText",
                                            identifier: sameIDs ? "row_\(row)" : "row_\(shift)_\(row)",
                                            label: "行\(row)", value: nil, placeholder: nil, enabled: true,
                                            frame: FTRect(x: 0, y: y, width: 400, height: 40), depth: 1))
            }
            // 動かない id 付きの見出し(場所シートのタブ等)。中身が動いても、これが多いと全要素の中央値は 0 になる
            for header in 0..<pinnedHeaders {
                elements.append(ElementInfo(ref: 100 + header, type: "button", identifier: "tab_\(header)", label: "タブ\(header)",
                                            value: nil, placeholder: nil, enabled: true,
                                            frame: FTRect(x: Double(header) * 20, y: 100, width: 20, height: 30), depth: 1))
            }
            return elements
        }
    }

    private func failureMessage(sameIDs: Bool, pinnedHeaders: Int = 0) async -> String {
        var step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "missing"), direction: "up", maxSwipes: 2)
        // 共通要素の無い形は容器にも id が無い(動かない容器の id が共通だと 0 と測る)ので、名指しせず画面の高さが基準
        if sameIDs { step.scrollFrame = FlowLocator(id: "list") }
        let driver = FakeAppDriver(name: "d", log: CallLog(), snapshotElements: screens(sameIDs: sameIDs, pinnedHeaders: pinnedHeaders))
        let outcome = await StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables(),
                                         uiFramework: .androidView).execute(step)
        guard case .failed(let message) = outcome.status else { XCTFail("\(outcome.status)"); return "" }
        return message
    }

    func testEachRoundSaysHowFarItMovedAgainstTheContainer() async {
        let message = await failureMessage(sameIDs: true)
        XCTAssertNotNil(message.range(of: #"round 1: not in the tree \(moved [1-9][0-9]* of 300\)"#, options: .regularExpression),
                        message)
    }

    func testARoundWithNothingInCommonSaysTheTravelIsUnknown() async {
        let message = await failureMessage(sameIDs: false)
        XCTAssertTrue(message.contains("(moved ? of 800 — no element in common with the previous read)"), message)
    }

    func testPinnedHeadersDoNotHideTheTravelOfTheRows() async {
        let message = await failureMessage(sameIDs: true, pinnedHeaders: 20)
        XCTAssertNotNil(message.range(of: #"round 1: not in the tree \(moved [1-9][0-9]* of 300\)"#, options: .regularExpression),
                        message)
    }
}
