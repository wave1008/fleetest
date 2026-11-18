// 横の払い直し先は、横へ動くと言える容器(申告か子の横の並び)だけを数える(DR-190)。
// 実測(SUT Store の iOS・XCUITest の木): 並べ替えチップの行もグリッドも容器として出ず、scroll 印は全画面の scrollView だけ。
// それを「横の唯一の容器」にして、縦の本体の中央をもう一度払っていた

import XCTest
@testable import FTCore

final class HorizontalRedirectContainerTests: XCTestCase {

    private func el(_ ref: Int, _ type: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double,
                    scrollable: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: "e\(ref)", label: nil, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: 1, scrollable: scrollable)
    }

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                         elements: elements, truncatedCount: 0)
    }

    func testAFullScreenContainerWithMixedChildrenIsNotTheHorizontalTarget() {
        let tree = snapshot([
            el(1, "scrollView", 0, 0, 402, 874, scrollable: true),
            el(2, "button", 16, 196, 87, 48), el(3, "button", 111, 196, 115, 48), el(4, "button", 235, 196, 116, 48),
            el(5, "button", 16, 268, 177, 257), el(6, "button", 209, 268, 177, 279),
        ])
        XCTAssertNil(ContainerGeometry.uniqueScrollContainer(in: tree, vertical: false))
        XCTAssertEqual(ContainerGeometry.uniqueScrollContainer(in: tree, vertical: true)?.ref, 1, "縦は従来どおり")
    }

    func testARowContainerIsStillTheHorizontalTarget() {
        let tree = snapshot([
            el(1, "scrollView", 0, 196, 402, 48, scrollable: true),
            el(2, "button", 16, 196, 87, 48), el(3, "button", 111, 196, 115, 48), el(4, "button", 235, 196, 116, 48),
        ])
        XCTAssertEqual(ContainerGeometry.uniqueScrollContainer(in: tree, vertical: false)?.ref, 1)
    }
}
