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
        XCTAssertEqual(RefGuard.ambiguousRetargetCount(target: old, found: found, moved: moved, in: fresh, taken: []), 3)
    }

    /// 行の高さの倍数だけ送られると別の行の chevron が同じ座標へ来る。動いていなくても親の行が違えば付け替え
    func testSameCoordinatesInADifferentRowIsAmbiguous() throws {
        func row(_ ref: Int, _ id: String, y: Double) -> ElementInfo {
            ElementInfo(ref: ref, type: "button", identifier: id, label: nil, value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 16, y: y, width: 370, height: 52), depth: 2)
        }
        let old = chevron(1, y: 300)
        let taken = [row(2, "nav_pager", y: 280), old]
        let moved = [row(3, "nav_grid", y: 280), chevron(4, y: 300), chevron(5, y: 352)]
        XCTAssertEqual(RefGuard.ambiguousRetargetCount(target: old, found: moved[1], moved: 0, in: moved, taken: taken), 2)
        let same = [row(3, "nav_pager", y: 280), chevron(4, y: 300), chevron(5, y: 352)]
        XCTAssertNil(RefGuard.ambiguousRetargetCount(target: old, found: same[1], moved: 0, in: same, taken: taken))
    }

    /// 動いていない・同じ id が1つだけなら付け替えではないので通す
    func testUnmovedOrUniqueRetargetIsNotAmbiguous() {
        let old = chevron(1, y: 300)
        let fresh = [chevron(10, y: 200), chevron(11, y: 300)]
        XCTAssertNil(RefGuard.ambiguousRetargetCount(target: old, found: fresh[1], moved: 0, in: fresh, taken: []))
        let single = [chevron(11, y: 285)]
        XCTAssertNil(RefGuard.ambiguousRetargetCount(target: old, found: single[0], moved: 15, in: single, taken: []))
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
