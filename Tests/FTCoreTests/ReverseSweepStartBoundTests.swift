// 逆走査は開始位置より先を探さない(DR-189)。実測(SUT Store の iOS・並べ替えの後): 先頭の行は送る前から画面の上に外れていて、
// inapp-boost では下へ送り切った後の逆走査が開始位置より上まで戻って見つけ、xcuitest(容器が木に出ず逆走査しない)と合否が割れた

import XCTest
@testable import FTCore

final class ReverseSweepStartBoundTests: XCTestCase {

    private func el(_ id: String, _ y: Double) -> ElementInfo {
        ElementInfo(ref: 0, type: "button", identifier: id, label: nil, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: 16, y: y, width: 177, height: 100), depth: 1)
    }

    private let list = FTRect(x: 0, y: 250, width: 402, height: 600)

    /// 指を下へ(中身が下へ戻る)動かして、送る前に y=300 だった行が y=420 に来た = 120 越えた
    func testCrossingIsTheShiftPastTheStartPosition() {
        let start = [el("row_a", 300), el("row_b", 450)]
        XCTAssertEqual(StepExecutor.reverseSweepCrossing(start: start, now: [el("row_a", 420)], region: list, finger: .down), 120)
        XCTAssertEqual(StepExecutor.reverseSweepCrossing(start: start, now: [el("row_b", 300)], region: list, finger: .down), 0,
                       "開始位置より手前(まだ戻り切っていない)")
        XCTAssertEqual(StepExecutor.reverseSweepCrossing(start: start, now: [el("row_c", 300)], region: list, finger: .down), 0,
                       "共通の要素が無ければ測れない = 0")
        XCTAssertEqual(StepExecutor.reverseSweepCrossing(start: start, now: [el("row_a", 301)], region: list, finger: .down), 0,
                       "整定の揺れ以下は越えていない")
    }

    func testFoundInTheCrossedBandIsBeyondTheStart() {
        // 120 越えた: 一覧の上端から 120 の帯は送る前の画面より上にあった
        XCTAssertTrue(StepExecutor.liesBeyondStart(FTRect(x: 16, y: 260, width: 177, height: 60), crossed: 120,
                                                   container: list, finger: .down))
        XCTAssertFalse(StepExecutor.liesBeyondStart(FTRect(x: 16, y: 500, width: 177, height: 60), crossed: 120,
                                                    container: list, finger: .down), "飛び越した区間(開始位置より下)は拾う")
        XCTAssertFalse(StepExecutor.liesBeyondStart(FTRect(x: 16, y: 260, width: 177, height: 60), crossed: 0,
                                                    container: list, finger: .down), "越えていなければ従来どおり")
    }

    func testBothCallSitesPassTheStartSnapshot() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTCore/StepExecutor+ScrollSearch.swift"), encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "searching: direction, start: startSnapshot,").count - 1, 2)
        XCTAssertTrue(source.contains("if attempt == 0 { startSnapshot = snapshot }"))
    }
}
