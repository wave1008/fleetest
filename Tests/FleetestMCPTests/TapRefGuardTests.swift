// tap と ref の誤った成功の塞ぎ(同 id の付け替え・返した木の窓・撃つ前の確認の配線)

import XCTest
import FTCore
@testable import fleetest_mcp

final class TapRefGuardTests: XCTestCase {
    private func chevron(_ ref: Int, y: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: "image", identifier: "chevron.forward", label: nil, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 350, y: y, width: 12, height: 20), depth: 3)
    }

    /// 同じ id が複数ある木で、採った要素から動いた位置のものへ付け替わるなら数を返す(撃たない)
    func testMovedRetargetAmongSameIdIsAmbiguous() throws {
        let old = chevron(1, y: 300)
        let fresh = [chevron(10, y: 200), chevron(11, y: 285), chevron(12, y: 370)]
        let found = try XCTUnwrap(RefGuard.match(old, in: fresh))
        let moved = RefGuard.distance(old.frame, found.frame)
        XCTAssertEqual(RefGuard.ambiguousRetargetCount(target: old, found: found, moved: moved, in: fresh), 3)
    }

    /// 動いていない・同じ id が1つだけなら付け替えではないので通す
    func testUnmovedOrUniqueRetargetIsNotAmbiguous() {
        let old = chevron(1, y: 300)
        let fresh = [chevron(10, y: 200), chevron(11, y: 300)]
        XCTAssertNil(RefGuard.ambiguousRetargetCount(target: old, found: fresh[1], moved: 0, in: fresh))
        let single = [chevron(11, y: 285)]
        XCTAssertNil(RefGuard.ambiguousRetargetCount(target: old, found: single[0], moved: 15, in: single))
    }

    /// 木を読み手へ返す口は返した世代の印を付ける・ref なしの入力は前面を確かめる・座標のない pinch と back も覆いを確かめる
    func testGuardsAreWiredIntoEveryReturningPath() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ name: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent("Sources/fleetest-mcp/\(name)"), encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        }
        let snapshot = try source("MCPServer+Snapshot.swift")
        XCTAssertEqual(snapshot.components(separatedBy: "markLastGenerationDelivered(args: args)").count - 1, 2,
                       "snapshotBody と ft_scroll_to の木が返した世代の印を付けていない")
        let screen = try source("MCPServer+ScreenTools.swift")
        XCTAssertEqual(screen.components(separatedBy: "refusalForRefLessInputOnOtherApp(").count - 1, 2,
                       "ft_type と ft_clear_input の ref なしが前面を確かめていない")
        let gestures = try source("MCPServer+GesturesTools.swift")
        XCTAssertTrue(gestures.contains("pinchResolvedRef == nil, pinchCoordinate == nil"))
        XCTAssertTrue(gestures.contains("verifiedTreeCoverWarning("))
    }
}
