import XCTest
@testable import FTCore

/// 可視性検証の赤に添える「スクロール容器に切られている」の事実。木は SUT Store のアカウント画面の
/// 実測(`fleetest snapshot --json` の in-app の木)から要る行だけを写した
final class ScrollContainerClipFactTests: XCTestCase {
    private static let json = """
    {"screen":{"x":0,"y":0,"width":402,"height":874},"truncatedCount":0,"safeAreaTop":{"measured":true,"top":62},"elements":[
     {"ref":1,"type":"other","identifier":"screen_account","enabled":true,"depth":8,"keptDepth":0,"frame":{"x":0,"y":62,"width":402,"height":698}},
     {"ref":3,"type":"other","enabled":true,"depth":8,"keptDepth":0,"scrollable":true,"frame":{"x":0,"y":188,"width":402,"height":538}},
     {"ref":7,"type":"button","identifier":"btn_orders","label":"注文履歴","enabled":true,"depth":10,"keptDepth":1,"frame":{"x":16,"y":300,"width":370,"height":56}},
     {"ref":22,"type":"button","identifier":"btn_logout","label":"ログアウト","enabled":true,"depth":10,"keptDepth":1,"frame":{"x":16,"y":717,"width":370,"height":43}},
     {"ref":23,"type":"staticText","label":"ログアウト","enabled":true,"depth":11,"keptDepth":2,"frame":{"x":166,"y":728.7,"width":70,"height":24.3}},
     {"ref":24,"type":"button","identifier":"tab_home","label":"ホーム","enabled":true,"depth":8,"keptDepth":0,"frame":{"x":0,"y":760,"width":74,"height":80}}
    ]}
    """

    private func elements() throws -> [ElementInfo] {
        try JSONDecoder().decode(SnapshotResponse.self, from: Data(Self.json.utf8)).elements
    }

    private func element(_ ref: Int) throws -> ElementInfo {
        try XCTUnwrap(try elements().first { $0.ref == ref })
    }

    func testButtonCutOffAtTheContainersBottomEdgeNamesTheContainer() throws {
        let scroller = TapTargetGeometry.centreOutsideScrollContainer(try element(22), in: try elements())
        XCTAssertEqual(scroller?.ref, 3)
        let fact = StepExecutor.scrollContainerClipFact(element: try element(22), elements: try elements())
        XCTAssertTrue(fact.contains("scrollTo"), fact)
    }

    func testRowInsideTheContainerSaysNothing() throws {
        XCTAssertNil(TapTargetGeometry.centreOutsideScrollContainer(try element(7), in: try elements()))
        XCTAssertEqual(StepExecutor.scrollContainerClipFact(element: try element(7), elements: try elements()), "")
    }

    /// 容器の外にあっても容器の子孫でない(タブバー)なら言わない
    func testElementOutsideButNotInTheContainerSaysNothing() throws {
        XCTAssertNil(TapTargetGeometry.centreOutsideScrollContainer(try element(24), in: try elements()))
    }
}
