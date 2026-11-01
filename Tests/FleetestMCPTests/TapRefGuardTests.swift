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
        XCTAssertEqual(try verdict(old, sameCoordinates, taken: taken), .differentRow(.identifier, taken: 1, now: 2))
        let moved = [row(3, "nav_grid", y: 265), chevron(4, y: 285), chevron(5, y: 337)]
        XCTAssertEqual(try verdict(old, moved, taken: taken), .differentRow(.identifier, taken: 1, now: 2))
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
        XCTAssertEqual(try verdict(old, fresh, taken: taken), .differentRow(.identifier, taken: 3, now: 1))
    }

    /// 親に id もラベルも無く行を区別できない: 動いたときだけ注記(断らない)・動かなければ通す
    func testIndistinctRowsOnlyNote() throws {
        let old = chevron(1, y: 300)
        let taken = [old, chevron(2, y: 352)]
        XCTAssertEqual(try verdict(old, [chevron(3, y: 280), chevron(4, y: 332)], taken: taken), .rowsIndistinct(.identifier, taken: 2, now: 2))
        XCTAssertEqual(try verdict(old, [chevron(3, y: 300), chevron(4, y: 352)], taken: taken), .proceed)
        // 採った木が無い = 行を比べられない
        XCTAssertEqual(try verdict(old, [chevron(3, y: 280), chevron(4, y: 332)], taken: []), .rowsIndistinct(.identifier, taken: 0, now: 2))
    }

    // MARK: - id の無い要素(ラベルで引き直す形)

    private func plain(_ ref: Int, _ label: String, y: Double, type: String = "button") -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: nil, label: label, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 327, y: y, width: 48, height: 43), depth: 3)
    }

    /// 実測の形: 行1で採った「削除」(id なし・1件)が、行3だけが開いた今の木の「削除」(105pt 下)へ付け替わる。
    /// 周りの行の id が違うので断る(件数はどちらも1件ずつ)
    func testIdlessButtonRetargetedToAnotherRowIsRefused() throws {
        let old = plain(1, "削除", y: 227)
        let taken = [row(2, "swipe_row_1", y: 200), old]
        let fresh = [row(3, "swipe_row_3", y: 305), plain(4, "削除", y: 332)]
        XCTAssertEqual(try verdict(old, fresh, taken: taken), .differentRow(.label, taken: 1, now: 1))
        let refusal = RefGuard.ambiguousRetargetRefusal(ref: 1, old: old, matcher: .label, taken: 1, now: 1)
        XCTAssertTrue(refusal.contains("matched 1 element(s) with the same label and type when snapshotted, 1 now"), refusal)
    }

    /// 同じ行のまま動いた(親ごと動く)・動かない・ボタン系でない型は断らない
    func testIdlessSameRowOrStaticOrUnmovedPasses() throws {
        let old = plain(1, "削除", y: 227)
        let taken = [row(2, "swipe_row_1", y: 200), old]
        XCTAssertEqual(try verdict(old, [row(3, "swipe_row_1", y: 150), plain(4, "削除", y: 177)], taken: taken), .proceed)
        // 動かなければ周りの顔ぶれが違っても通す
        XCTAssertEqual(try verdict(old, [row(3, "swipe_row_3", y: 200), plain(4, "削除", y: 227)], taken: taken), .proceed)
        let text = plain(1, "削除", y: 227, type: "staticText")
        let freshText = [row(3, "swipe_row_3", y: 305), plain(4, "削除", y: 332, type: "staticText")]
        XCTAssertEqual(try verdict(text, freshText, taken: [row(2, "swipe_row_1", y: 200), text]), .proceed)
    }

    /// 周りで行を区別できない形: 仲間との間隔の半分以上動いたら断る・半分未満なら注記だけ・仲間が居なければ注記だけ
    func testIdlessIndistinctRowsRefuseOnlyPastHalfThePitch() throws {
        let old = plain(1, "削除", y: 200)
        let taken = [old, plain(2, "削除", y: 300)]
        XCTAssertEqual(try verdict(old, [plain(3, "削除", y: 250), plain(4, "削除", y: 350)], taken: taken),
                       .travelledPastNeighbour(taken: 2, now: 2))
        XCTAssertEqual(try verdict(old, [plain(3, "削除", y: 230), plain(4, "削除", y: 330)], taken: taken),
                       .rowsIndistinct(.label, taken: 2, now: 2))
        XCTAssertEqual(try verdict(old, [plain(3, "削除", y: 150)], taken: [old]), .rowsIndistinct(.label, taken: 1, now: 1))
    }

    /// 実測の木(E2EX-iOS スワイプで削除): 行の id は「削除」の親に出ない。周りが揃って動かないので断る。
    /// スクロール(周りも同じだけ動く)は注記のまま・子の文字が一緒に動いても「揃った」に数えない
    func testIdlessButtonThatMovedAloneIsRefused() throws {
        func narrowRow(_ ref: Int, _ id: String, y: Double) -> ElementInfo {
            ElementInfo(ref: ref, type: "staticText", identifier: id, label: nil, value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: -52, y: y, width: 370, height: 52), depth: 2)
        }
        let rows = [narrowRow(10, "swipe_row_1", y: 223), narrowRow(11, "swipe_row_3", y: 328)]
        let old = plain(1, "削除", y: 227)
        func text(_ ref: Int, y: Double) -> ElementInfo {
            ElementInfo(ref: ref, type: "staticText", identifier: nil, label: "削除", value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 339, y: y, width: 24, height: 15), depth: 4)
        }
        let oldText = text(2, y: 241)
        let moved = plain(3, "削除", y: 332)
        let movedText = text(4, y: 346)
        XCTAssertEqual(try verdict(old, rows + [moved, movedText], taken: rows + [old, oldText]), .movedAlone)

        let scrolled = [narrowRow(12, "swipe_row_1", y: 328), narrowRow(13, "swipe_row_3", y: 433)]
        XCTAssertEqual(try verdict(old, scrolled + [moved, movedText], taken: rows + [old, oldText]),
                       .rowsIndistinct(.label, taken: 1, now: 1))
    }

    /// CMP のボタンは子に同じ文字の staticText を出す。押してラベルが変わっても子の文字は行の顔ぶれに数えない = 2回目も通る
    func testChildTextOfTheButtonIsNotPartOfItsRow() throws {
        func toggle(_ ref: Int, _ label: String) -> ElementInfo {
            ElementInfo(ref: ref, type: "button", identifier: "btn_ticker_toggle", label: label, value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 220, y: 182, width: 116, height: 48), depth: 10)
        }
        func child(_ ref: Int, _ label: String) -> ElementInfo {
            ElementInfo(ref: ref, type: "staticText", identifier: "txt_\(label)", label: label, value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 240, y: 192, width: 80, height: 28), depth: 11)
        }
        func screen(_ ids: [String]) -> [ElementInfo] {
            ids.enumerated().map { row(100 + $0.offset, $0.element, y: 400 + Double($0.offset) * 60) }
        }
        let common = ["a", "b", "c", "d"]
        let old = toggle(1, "ティッカー開始")
        let taken = [old, child(2, "ティッカー開始")] + screen(common)
        let fresh = [toggle(3, "ティッカー停止"), child(4, "ティッカー停止")] + screen(common)
        XCTAssertEqual(try verdict(old, fresh, taken: taken, acted: true), .proceed)
    }

    /// 断りの文は採った木の件数と今の木の件数を別々に言う(今の木で1件なのに「now matches 3」と言わない)
    func testRefusalSaysTakenAndNowCountsSeparately() {
        let old = chevron(1, y: 300)
        let text = RefGuard.ambiguousRetargetRefusal(ref: 1, old: old, matcher: .identifier, taken: 3, now: 1)
        XCTAssertTrue(text.contains("3 element(s) with the same id when snapshotted, 1 now"), text)
        XCTAssertFalse(text.contains("now matches"), text)
    }

    /// ghost の ref は ft_tap / long_press(verifiedRef)も double_tap / drag / pinch(verifiedElement)も同じ警告を付ける
    func testGhostWarningIsAttachedOnBothRefEntries() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["MCPServer+Snapshot.swift", "MCPServer+Dispatch.swift"] {
            let code = try String(contentsOf: root.appendingPathComponent("Sources/fleetest-mcp/\(name)"), encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            XCTAssertTrue(code.contains("RefGuard.ghostWarning("), "\(name): .ghost の経路に ghostWarning が無い")
        }
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
