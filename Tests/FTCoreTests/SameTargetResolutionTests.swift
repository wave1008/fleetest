// 自分の動きの後の引き直しが「撃つと決めた要素」を返すことの固定。木は E2EX-iOS の無限スクロール(in-app)で、
// 寄せの前(19 のセルが最上段)と後(18 のセルが上から入った)を実際に撮ったもの
import XCTest
@testable import FTCore

final class SameTargetResolutionTests: XCTestCase {

    private func tree(_ name: String) throws -> SnapshotResponse {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/OwnMoveTrees/\(name).json")
        return try JSONDecoder().decode(SnapshotResponse.self, from: Data(contentsOf: url))
    }

    private func firstClickable() -> FlowStep {
        FlowStep(action: "tap", locator: FlowLocator(type: "clickable", index: 0))
    }

    /// 寄せの後にセレクタで引き直すと 18 のセルになる(前提)が、撃つと決めた 19 のセルを返す
    func testOrdinalSelectorKeepsTheCellDecidedBeforeTheNudge() throws {
        let before = try tree("ios-inapp-infinite-before-nudge")
        let after = try tree("ios-inapp-infinite-after-nudge")
        let step = firstClickable()
        let (original, _) = try XCTUnwrap(LocatorResolver.resolve(step: step, in: before))
        let (plain, _) = try XCTUnwrap(LocatorResolver.resolve(step: step, in: after))
        XCTAssertEqual(LocatorResolver.descendants(of: plain, in: after.elements).first?.identifier, "row_i_18", "前提")
        let (same, _) = try XCTUnwrap(SameTargetResolution.resolve(step: step, original: original,
                                                                   originalElements: before.elements, in: after))
        XCTAssertEqual(LocatorResolver.descendants(of: same, in: after.elements).first?.identifier, "row_i_19")
        XCTAssertEqual(same.type, "clickable")
    }

    /// 撃つと決めた要素が新しい木から消えたら、セレクタが別の要素を返しても引かない(撃つと別の物を押す)
    func testGoneTargetIsNotReplacedByAnotherMatch() throws {
        let before = try tree("ios-inapp-infinite-before-nudge")
        var after = try tree("ios-inapp-infinite-after-nudge")
        after.elements.removeAll { $0.identifier == "row_i_19" }
        let step = firstClickable()
        let (original, _) = try XCTUnwrap(LocatorResolver.resolve(step: step, in: before))
        XCTAssertNotNil(LocatorResolver.resolve(step: step, in: after), "前提: セレクタは何かを返す")
        XCTAssertNil(SameTargetResolution.resolve(step: step, original: original, originalElements: before.elements, in: after))
    }

    /// 識別できる物が何も無い要素は従来どおりセレクタで引く
    func testUnidentifiableElementFallsBackToTheSelector() throws {
        let el = ElementInfo(ref: 1, type: "other", identifier: nil, label: nil, value: nil, placeholder: nil,
                             enabled: true, frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 1)
        XCTAssertNil(SameTargetResolution.key(of: el, in: [el]))
        let after = try tree("ios-inapp-infinite-after-nudge")
        let step = firstClickable()
        XCTAssertEqual(SameTargetResolution.resolve(step: step, original: el, originalElements: [el], in: after)?.0.ref,
                       LocatorResolver.resolve(step: step, in: after)?.0.ref)
    }

    /// 自分の動きの後の引き直しは共有の関数を通る(セレクタで直に引き直すと、序数・ワイルドカードが動いた一覧の別の行を返す)
    func testOwnMoveSitesUseTheSharedResolution() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ name: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent("Sources/FTCore/\(name)"), encoding: .utf8)
        }
        let counts: [(String, Int)] = [("StepExecutor+Actions.swift", 8), ("StepExecutor+PreTouch.swift", 2),
                                       ("StepExecutor+TypeClear.swift", 1), ("StepExecutor+Settle.swift", 3)]
        for (file, expected) in counts {
            XCTAssertEqual(try source(file).components(separatedBy: "SameTargetResolution.resolve(").count - 1, expected, file)
        }
    }
}
