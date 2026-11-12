// ft_tap / ft_type / ft_long_press / ft_double_tap / ft_clear_input の `selector`:
// DSL と同じ解決で ref の経路へ畳まれ、一致なしは何も撃たず、下書きは渡された selector を書く。

import XCTest
import FTCore
@testable import fleetest_mcp

final class SelectorTargetTests: XCTestCase {

    private func element(_ ref: Int, id: String?, label: String, y: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: "button", identifier: id, label: label, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 0, y: y, width: 200, height: 40), depth: 1)
    }

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                         elements: elements, truncatedCount: 0)
    }

    private func make(_ elements: [ElementInfo]) -> (MCPServer, FakeDriver) {
        let fake = FakeDriver()
        fake.foregroundBundleID = "com.example.app"
        fake.snapshotResponse.elements = elements
        let server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
        return (server, fake)
    }

    private func texts(_ result: [[String: Any]]) -> String {
        result.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    // MARK: - 解決は DSL と同じ

    /// 純粋な解決が `LocatorResolver` の答えと同じ要素・複数一致の注記は先頭の要素を名指しする
    func testResolutionPicksTheElementTheDSLResolverPicks() throws {
        let tree = snapshot([element(1, id: nil, label: "Save", y: 0),
                                                  element(2, id: nil, label: "Save", y: 50),
                                                  element(3, id: "cancel", label: "Cancel", y: 100)])
        let step = FlowStep(action: "tap", locator: FTSelector.parse("Save").primary)
        let dsl = try XCTUnwrap(LocatorResolver.resolve(step: step, in: tree)).0
        let picked = try MCPServer.resolveSelectorTarget("Save", in: tree)
        XCTAssertEqual(picked.element.ref, dsl.ref)
        XCTAssertTrue(picked.note.contains("matched 2 separate elements; acted on [\(dsl.ref)]"), picked.note)
        XCTAssertTrue(picked.note.contains("a scenario line would pick"), picked.note)
        XCTAssertEqual(try MCPServer.resolveSelectorTarget("#cancel", in: tree).note, "", "一意なら注記なし")
    }

    /// ボタンとその中の文字が同じラベル(入れ子)= 同じ部品なので複数一致と言わない(実測: Apple マップの「今はしない」)
    func testNestedSameLabelIsNotReportedAsAmbiguous() throws {
        let tree = snapshot([element(1, id: nil, label: "Later", y: 0),
                             ElementInfo(ref: 2, type: "staticText", identifier: nil, label: "Later", value: nil,
                                         placeholder: nil, enabled: true,
                                         frame: FTRect(x: 10, y: 5, width: 100, height: 30), depth: 2)])
        let picked = try MCPServer.resolveSelectorTarget("Later", in: tree)
        XCTAssertEqual(picked.element.ref, 1)
        XCTAssertEqual(picked.note, "")
    }

    /// 序数 `[n]` は自分で選んだ書き方なので複数一致の注記を出さない
    func testOrdinalSelectorIsNotReportedAsAmbiguous() throws {
        let tree = snapshot([element(1, id: nil, label: "Save", y: 0),
                                                  element(2, id: nil, label: "Save", y: 50)])
        let picked = try MCPServer.resolveSelectorTarget(".button[2]", in: tree)
        XCTAssertEqual(picked.element.ref, 2)
        XCTAssertEqual(picked.note, "")
    }

    // MARK: - ref の経路へ畳む

    /// selector で撃つと ref の経路(ネイティブ ref の tap)に着き、複数一致の注記が応答の先頭に付く
    func testTapBySelectorGoesThroughTheRefPath() async throws {
        let (server, fake) = make([element(1, id: nil, label: "Save", y: 0),
                                   element(2, id: nil, label: "Save", y: 50)])
        let text = texts(try await server.call(tool: "ft_tap", args: ["selector": "Save"]))
        XCTAssertTrue(fake.calls.contains { $0.hasPrefix("tap(ref:") }, "\(fake.calls)")
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("tap(x:") }, "\(fake.calls)")
        XCTAssertTrue(text.hasPrefix("note: selector Save matched 2 separate elements"), text)
    }

    func testEveryOperationToolAcceptsSelector() {
        for tool in MCPServer.selectorTargetTools {
            let props = (MCPServer.toolDefinitions.first { $0["name"] as? String == tool }?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
            XCTAssertNotNil(props?["selector"], "\(tool) に selector が無い")
        }
        XCTAssertEqual(MCPServer.selectorTargetTools,
                       ["ft_tap", "ft_type", "ft_long_press", "ft_double_tap", "ft_clear_input"])
    }

    // MARK: - 排他

    func testRefAndSelectorTogetherAreRefused() {
        for tool in MCPServer.selectorTargetTools {
            XCTAssertNotNil(MCPServer.targetExclusivityViolation(tool: tool, args: ["ref": 1, "selector": "Save"]), tool)
            XCTAssertNil(MCPServer.targetExclusivityViolation(tool: tool, args: ["selector": "Save"]), tool)
        }
        for tool in ["ft_tap", "ft_double_tap", "ft_long_press"] {
            XCTAssertNotNil(MCPServer.targetExclusivityViolation(tool: tool, args: ["selector": "Save", "x": 1.0, "y": 2.0]), tool)
        }
    }

    // MARK: - 一致なし

    /// 一致なしは何も撃たず、近いラベルを添えて断る
    func testNoMatchRefusesWithoutSendingAnything() async throws {
        let (server, fake) = make([element(1, id: nil, label: "Save", y: 0)])
        do {
            _ = try await server.call(tool: "ft_tap", args: ["selector": "Savee"])
            XCTFail("一致なしは断るはず")
        } catch {
            let message = (error as? MCPError)?.message ?? "\(error)"
            XCTAssertTrue(message.contains("no element matches Savee") && message.contains("nothing was sent"), message)
            XCTAssertTrue(message.contains("Save"), "近いラベルを添える: \(message)")
        }
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("tap(") }, "\(fake.calls)")
    }

    /// **アプリ内アラートの陰で一致しなかったら、アラートを先頭に書く**(末尾だと「要素が無い」と誤読された = Apple マップの計測)
    func testNoMatchBehindAnInAppAlertLeadsWithTheAlert() async throws {
        let alert = ElementInfo(ref: 10, type: "alert", identifier: nil, label: "安全に目的地に到達するために", value: nil,
                                placeholder: nil, enabled: true, frame: FTRect(x: 10, y: 300, width: 360, height: 200), depth: 1)
        let ok = ElementInfo(ref: 11, type: "button", identifier: nil, label: "OK", value: nil, placeholder: nil,
                             enabled: true, frame: FTRect(x: 20, y: 440, width: 100, height: 40), depth: 2)
        let (server, fake) = make([alert, ok])
        do {
            _ = try await server.call(tool: "ft_tap", args: ["selector": "#TransitButton"])
            XCTFail("一致なしは断るはず")
        } catch {
            let message = (error as? MCPError)?.message ?? "\(error)"
            XCTAssertTrue(message.hasPrefix("refusing: "), message)
            let alertAt = try XCTUnwrap(message.range(of: "安全に目的地に到達するために"), message)
            let missAt = try XCTUnwrap(message.range(of: "no element matches #TransitButton"), message)
            XCTAssertTrue(alertAt.lowerBound < missAt.lowerBound, "アラートが先: \(message)")
            XCTAssertTrue(message.contains("[11] \"OK\""), message)
        }
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("tap(") }, "\(fake.calls)")
    }

    /// 文法の誤りはアラートが前面でもアラートを名指さない(閉じても直らない)
    func testSyntaxErrorBehindAnAlertDoesNotNameTheAlert() async throws {
        let alert = ElementInfo(ref: 10, type: "alert", identifier: nil, label: "安全に目的地に到達するために", value: nil,
                                placeholder: nil, enabled: true, frame: FTRect(x: 10, y: 300, width: 360, height: 200), depth: 1)
        let ok = ElementInfo(ref: 11, type: "button", identifier: nil, label: "OK", value: nil, placeholder: nil,
                             enabled: true, frame: FTRect(x: 20, y: 440, width: 100, height: 40), depth: 2)
        let (server, _) = make([alert, ok])
        do {
            _ = try await server.call(tool: "ft_tap", args: ["selector": "#"])
            XCTFail("文法の誤りは断るはず")
        } catch {
            let message = (error as? MCPError)?.message ?? "\(error)"
            XCTAssertFalse(message.contains("安全に目的地に到達するために"), message)
            XCTAssertFalse(message.hasPrefix("refusing: "), message)
        }
    }

    /// アラートが無ければ従来の文のまま(先頭に何も足さない)
    func testSelectorMissMessageWithoutAlertIsUnchanged() {
        XCTAssertEqual(MCPServer.selectorMissMessage("no element matches X", alertClause: ""), "no element matches X")
    }

    /// 遷移の直後で1回目の読みに無くても、シナリオの行と同じ回数だけ撮り直して探す(2回目に現れたら撃つ)
    func testSelectorIsSearchedAgainLikeAScenarioLine() async throws {
        let (server, fake) = make([])
        var empty = fake.snapshotResponse
        empty.elements = []
        var arrived = fake.snapshotResponse
        arrived.elements = [element(1, id: "transit", label: "交通機関", y: 0)]
        fake.scriptedSnapshots = [empty, arrived]
        _ = try await server.call(tool: "ft_tap", args: ["selector": "#transit"])
        XCTAssertTrue(fake.calls.contains { $0.hasPrefix("tap(") }, "2回目の読みで現れた要素を撃つ: \(fake.calls)")
    }

    // MARK: - 下書き

    /// 下書きは推奨形でなく、渡された selector を書く
    func testDraftRecordsTheGivenSelector() async throws {
        let (server, _) = make([element(1, id: "save_btn", label: "Save", y: 0)])
        _ = try await server.call(tool: "ft_tap", args: ["selector": "Save"])
        let draft = texts(try await server.call(tool: "ft_draft_scenario", args: ["all": true]))
        XCTAssertTrue(draft.contains("tap(\"Save\""), draft)
        XCTAssertFalse(draft.contains("#save_btn"), "推奨の #id でなく渡された selector: \(draft)")
        XCTAssertFalse(draft.contains("index-based selector"), "一意に当たった書き方は位置依存と言わない: \(draft)")
    }

    /// `a||b` で後ろ側が当たったときは、当たった側で数える(先頭の外れた側で数えて安定に見せない)
    func testDraftCountsTheFallbackThatActuallyMatched() async throws {
        let (server, _) = make([element(1, id: nil, label: "OK", y: 0), element(2, id: nil, label: "OK", y: 100)])
        _ = try await server.call(tool: "ft_tap", args: ["selector": "Missing||OK"])
        let draft = texts(try await server.call(tool: "ft_draft_scenario", args: ["all": true]))
        XCTAssertTrue(draft.contains("index-based selector"), draft)
    }

    /// 別々の複数に当たった selector は木の順に頼る = 下書きは位置依存の注意を付ける(安定に見せない)
    func testDraftMarksAMultiMatchSelectorAsPositional() async throws {
        let (server, _) = make([element(1, id: nil, label: "OK", y: 0), element(2, id: nil, label: "OK", y: 100)])
        _ = try await server.call(tool: "ft_tap", args: ["selector": "OK"])
        let draft = texts(try await server.call(tool: "ft_draft_scenario", args: ["all": true]))
        XCTAssertTrue(draft.contains("tap(\"OK\""), draft)
        XCTAssertTrue(draft.contains("index-based selector"), draft)
    }
}
