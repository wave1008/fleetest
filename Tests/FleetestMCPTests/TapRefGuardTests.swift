// tap と ref の誤った成功の塞ぎ(同 id の付け替え・返した木の窓・撃つ前の確認の配線)

import XCTest
import FTCore
@testable import fleetest_mcp

final class TapRefGuardTests: XCTestCase {
    private func chevron(_ ref: Int, y: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: "image", identifier: "chevron.forward", label: nil, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 350, y: y, width: 12, height: 20), depth: 3)
    }

    private func row(_ ref: Int, _ id: String, y: Double, label: String? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: "button", identifier: id, label: label, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 16, y: y, width: 370, height: 52), depth: 2)
    }

    private func verdict(_ old: ElementInfo, _ fresh: [ElementInfo], taken: [ElementInfo],
                         acted: Bool = false) throws -> RefGuard.RetargetVerdict {
        let found = try XCTUnwrap(RefGuard.match(old, in: fresh))
        return RefGuard.retargetVerdict(target: old, found: found, in: fresh, taken: taken, ownActionSince: acted)
    }

    /// 別の行の同じ部品へ付け替わる(親の顔ぶれが違う)なら断る。座標が同じでも・動いていても同じ
    func testDifferentParentRowIsRefused() throws {
        let old = chevron(1, y: 300)
        let taken = [row(2, "nav_pager", y: 280), old]
        let sameCoordinates = [row(3, "nav_grid", y: 280), chevron(4, y: 300), chevron(5, y: 352)]
        XCTAssertEqual(try verdict(old, sameCoordinates, taken: taken), .differentRow(count: 2))
        let moved = [row(3, "nav_grid", y: 265), chevron(4, y: 285), chevron(5, y: 337)]
        XCTAssertEqual(try verdict(old, moved, taken: taken), .differentRow(count: 2))
    }

    /// 同じ行が動いただけ(親ごと動く)は通す = sim F2。動いた距離では決めない
    func testSameRowMovedIsNotRefused() throws {
        let old = chevron(1, y: 300)
        let taken = [row(2, "nav_pager", y: 280), old, chevron(5, y: 352)]
        let fresh = [row(3, "nav_pager", y: 265), chevron(4, y: 285), chevron(6, y: 337)]
        XCTAssertEqual(try verdict(old, fresh, taken: taken), .proceed)
    }

    /// 採った木で同 id が複数あれば、今の木で1件だけ残っても別の行なら断る = sim F1
    func testSingleSurvivorOfSeveralIsRefusedWhenRowDiffers() throws {
        let old = chevron(1, y: 300)
        let taken = [row(2, "group_fruit", y: 280), old, row(3, "group_veg", y: 340), chevron(4, y: 360),
                     row(5, "group_drink", y: 400), chevron(6, y: 420)]
        let fresh = [row(7, "group_drink", y: 280), chevron(8, y: 300)]
        XCTAssertEqual(try verdict(old, fresh, taken: taken), .differentRow(count: 3))
    }

    /// 親に id もラベルも無く行を区別できない: 動いたときだけ注記(断らない)・動かなければ通す
    func testIndistinctRowsOnlyNote() throws {
        let old = chevron(1, y: 300)
        let taken = [old, chevron(2, y: 352)]
        XCTAssertEqual(try verdict(old, [chevron(3, y: 280), chevron(4, y: 332)], taken: taken), .rowsIndistinct(count: 2))
        XCTAssertEqual(try verdict(old, [chevron(3, y: 300), chevron(4, y: 352)], taken: taken), .proceed)
        // 採った木が無い = 行を比べられない
        XCTAssertEqual(try verdict(old, [chevron(3, y: 280), chevron(4, y: 332)], taken: []), .rowsIndistinct(count: 2))
    }

    /// 同じ id が1つだけ(どの木でも)なら付け替えではない
    func testUniqueIdIsNotAmbiguous() throws {
        let old = chevron(1, y: 300)
        XCTAssertEqual(try verdict(old, [chevron(11, y: 285)], taken: [old]), .proceed)
    }

    /// 押すとラベルが変わるトグル(同じ枠・同じ周り・画面の識別子が残る)は操作の後でも通す = sim F5。
    /// 画面が替わって同じ枠に同じ id の別ラベルが来た形は断る
    func testToggleLabelChangeAfterOwnActionPassesButScreenSwapRefuses() throws {
        func button(_ ref: Int, _ label: String) -> ElementInfo {
            ElementInfo(ref: ref, type: "button", identifier: "btn_ticker_toggle", label: label, value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 205, y: 200, width: 135, height: 62), depth: 2)
        }
        func screen(_ ids: [String]) -> [ElementInfo] {
            ids.enumerated().map { row(100 + $0.offset, $0.element, y: 400 + Double($0.offset) * 60) }
        }
        let common = ["a", "b", "c", "d"]
        let old = button(1, "ティッカー開始")
        XCTAssertEqual(try verdict(old, [button(2, "ティッカー停止")] + screen(common), taken: [old] + screen(common), acted: true), .proceed)
        XCTAssertEqual(try verdict(old, [button(2, "ティッカー停止")] + screen(["x", "y", "z", "d"]), taken: [old] + screen(common), acted: true),
                       .labelChangedElsewhere)
        // 操作を挟んでいなければ従来どおり注記だけ
        XCTAssertEqual(try verdict(old, [button(2, "ティッカー停止")] + screen(["x", "y", "z", "d"]), taken: [old] + screen(common)), .proceed)
    }

    /// 既定値はリテラルで固定する
    func testSameScreenShareIsPinned() {
        XCTAssertEqual(RefGuard.sameScreenIdentifierShare, 0.5)
    }

    /// ref を撃つ前に付け替えを確かめる経路は全部 `retargetNote` の1つの口を通す(新しい経路が素通りすると落ちる)
    func testEveryRefPathGoesThroughTheSingleRetargetEntry() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("Sources/fleetest-mcp")
        var entries: [String: Int] = [:], relocates: [String: Int] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".swift") {
            let code = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            entries[name] = code.components(separatedBy: "Self.retargetNote(").count - 1
            relocates[name] = code.components(separatedBy: "let outcome = RefGuard.relocate(").count - 1
            XCTAssertFalse(code.contains("ambiguousRetargetCount"), "\(name): 旧い入口が残っている")
        }
        // ref を撃つ前に relocate して outcome を取る形は、同じ数だけ retargetNote を呼ぶ
        for (name, count) in relocates where count > 0 {
            XCTAssertEqual(entries[name], count, "\(name): relocate の結果が retargetNote を通っていない")
        }
        XCTAssertEqual(entries["MCPServer+Snapshot.swift"], 2, "verifiedRef と scrollFrame の ref")
        XCTAssertEqual(entries["MCPServer+Dispatch.swift"], 1, "verifiedElement")
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
        XCTAssertTrue(try source("MCPServer+Batch.swift").contains("refusalForRefLessBatchStep("),
                      "ft_batch の ref なし入力が前面を確かめていない")
        let gestures = try source("MCPServer+GesturesTools.swift")
        XCTAssertTrue(gestures.contains("pinchResolvedRef == nil, pinchCoordinate == nil"))
        XCTAssertTrue(gestures.contains("verifiedTreeCoverWarning("))
    }
}
