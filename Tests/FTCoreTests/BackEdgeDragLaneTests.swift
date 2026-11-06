// back() の左端エッジスワイプの高さ: 道筋が押せる要素の枠を横切らない高さを選ぶ(真ん中固定ではボタンが押された = 26周目 iultra F1/F2)

import XCTest
@testable import FTCore

final class BackEdgeDragLaneTests: XCTestCase {
    private let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
    private func el(_ type: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> ElementInfo {
        ElementInfo(ref: 1, type: type, identifier: nil, label: "x", value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: x, y: y, width: w, height: h), depth: 1)
    }

    func testAvoidsAButtonOnTheMiddleLane() {
        let submit = el("button", 20, 380, 200, 44)   // 真ん中(400)を横切る
        let y = BackEdgeDragLane.y(elements: [submit], screen: screen, fromX: 1, toX: 260)
        XCTAssertNotEqual(y, 400)
        XCTAssertFalse(y >= 380 - BackEdgeDragLane.fingerSlop && y <= 424 + BackEdgeDragLane.fingerSlop, "\(y) はボタンの帯の中")
    }

    func testKeepsTheMiddleWhenNothingIsInTheWay() {
        let label = el("staticText", 20, 380, 200, 44)   // 押せない要素は避けない
        let farRight = el("button", 300, 380, 80, 44)     // 道筋(〜260)の外
        XCTAssertEqual(BackEdgeDragLane.y(elements: [label, farRight], screen: screen, fromX: 1, toX: 260), 400)
    }

    func testFallsBackToTheMiddleWhenEveryLaneIsTaken() {
        let wall = el("button", 0, 150, 400, 500)   // 試す高さ(0.25〜0.75 = 200〜600)を全部覆う
        XCTAssertEqual(BackEdgeDragLane.y(elements: [wall], screen: screen, fromX: 1, toX: 260), 400)
    }

    /// 配線: back() のエッジスワイプがこの高さを使う(ソース走査。ブリッジ無しでは drag を通せない)
    func testBackUsesTheLane() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FTBridgeClient/BridgeClient.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("BackEdgeDragLane.y(elements: tree.elements, screen: screen, fromX: fromX, toX: toX)"))
        XCTAssertFalse(source.contains("fromY: screen.y + screen.height * 0.5,"), "真ん中固定のエッジスワイプが残っている")
    }
}
