// ft_dsl_commands が名指しのコマンドに添える注意事項(CommandCaveats)。一覧の項目の拾い方・関数表からのコマンド名の拾い方と、
// 実際のクローンの docs に届いていること

import XCTest
@testable import FTCore

final class CommandCaveatsTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testCaveatLinesKeepOnlyCommandPagesInOrder() {
        let index = """
            # Known caveats
            - [First](../commands/tap.md#notes) — what happens and how to write it.
            - [Gist only](../commands/tap.md#notes)
            - [Component](ui_component_patterns.md#input-types) — not a command page.
            - [Other](../commands/type.md#notes) — typing.
            Prose [x](../commands/tap.md#notes) — not a bullet.
            """
        XCTAssertEqual(CommandCaveats.caveatLines(index: index), [
            "tap.md": ["First — what happens and how to write it.", "Gist only"],
            "type.md": ["Other — typing."],
        ])
    }

    func testFunctionNamesComeFromTheFunctionTableOnlyAndTakeTheLastCallOfAChain() {
        let page = """
            # tap
            ## Functions
            | function | description |
            |---|---|
            | `tap(sel, waitSeconds:)` | Taps. Mentions `type("x")` in the description. |
            | `select(selector).textIs(expected)` / `rotateTo(.portrait)` | Chained and two forms. |
            ## Example
            | `swipe()` | not the function table |
            """
        XCTAssertEqual(CommandCaveats.functionNames(in: page), ["tap", "textIs", "rotateTo"])
    }

    func testEveryCommandOfAPageGetsThatPagesCaveats() {
        let caveats = CommandCaveats(
            index: "- [A](../commands/navigation.md#notes) — a.\n- [B](../commands/navigation.md#notes) — b.\n",
            commandPages: ["navigation.md": "## Functions\n| f | d |\n|---|---|\n| `home()` | x |\n| `back(settle:)` | y |\n",
                           "wait.md": "## Functions\n| f | d |\n|---|---|\n| `wait(1)` | z |\n"])
        XCTAssertEqual(caveats.byCommand, ["home": ["A — a.", "B — b."], "back": ["A — a.", "B — b."]])
    }

    /// 実際のクローンの docs から引ける(一覧の場所・ページの書き方が変わって黙って空になる形を落とす)
    func testRealDocsGiveCaveatsToCommandsThatHaveThem() throws {
        let caveats = try XCTUnwrap(CommandCaveats.load(toolRoot: Self.repoRoot))
        XCTAssertGreaterThanOrEqual(caveats.byCommand["tap"]?.count ?? 0, 10)
        XCTAssertGreaterThanOrEqual(caveats.byCommand["home"]?.count ?? 0, 10, "navigation のページ")
        XCTAssertGreaterThan(caveats.byCommand["textIs"]?.count ?? 0, 0)
        XCTAssertGreaterThan(caveats.byCommand.count, 40)
        XCTAssertNil(CommandCaveats.load(toolRoot: Self.repoRoot.appendingPathComponent("no-such-dir")))
    }
}
