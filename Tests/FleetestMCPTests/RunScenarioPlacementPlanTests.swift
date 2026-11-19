import XCTest
import FTCore
@testable import fleetest_mcp

/// ft_run_scenario のクラスの寄せ方(RR-8.3): @RunInOrder の途中の1本は撃つ前に断る・寄せるクラスは order 順に並べる
final class RunScenarioPlacementPlanTests: XCTestCase {
    private let a = ScenarioInfo(id: "C.a", title: "a", placement: .inOrder, order: 1)
    private let b = ScenarioInfo(id: "C.b", title: "b", placement: .inOrder, order: 2)

    func testMiddleTestOfAnInOrderClassIsRefused() {
        XCTAssertThrowsError(try MCPServer.placementPlan(selected: [b], all: [a, b])) { error in
            XCTAssertTrue((error as? MCPError)?.message.contains("@RunInOrder") == true, "\(error)")
        }
    }

    func testWholeClassIsOrderedByOrder() throws {
        XCTAssertEqual(try MCPServer.placementPlan(selected: [b, a], all: [a, b]).map(\.id), ["C.a", "C.b"])
    }

    func testPlainSelectionIsUntouched() throws {
        let p = ScenarioInfo(id: "P.a", title: "p")
        XCTAssertEqual(try MCPServer.placementPlan(selected: [p], all: [p]).map(\.id), ["P.a"])
    }
}
