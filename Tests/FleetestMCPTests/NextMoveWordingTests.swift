// 断り・失敗文が次の一手を言う(ft_tap の scroll・ft_batch の launch・id を素のラベルで書いた)

import XCTest
import FTCore
@testable import fleetest_mcp

final class NextMoveWordingTests: XCTestCase {

    func testTapScrollRefusalPointsAtScrollTo() {
        let refusal = MCPServer.unknownArgumentRefusal(tool: "ft_tap", args: ["selector": "Save", "scroll": "down"]) ?? ""
        XCTAssertTrue(refusal.contains("ft_scroll_to it first"), refusal)
        XCTAssertTrue(refusal.contains("tap(selector, scroll: .down)"), refusal)
        for tool in ["ft_long_press", "ft_double_tap", "ft_type"] {
            let note = MCPServer.unknownArgumentNote(tool: tool, args: ["scroll": "down"])
            XCTAssertTrue(note.contains("ft_scroll_to it first"), "\(tool): \(note)")
        }
    }

    func testSwipeDirectionRefusalNamesFinger() {
        let refusal = MCPServer.unknownArgumentRefusal(tool: "ft_swipe", args: ["direction": "down"]) ?? ""
        XCTAssertTrue(refusal.contains("takes the finger's movement as finger"), refusal)
        XCTAssertTrue(refusal.contains("ft_scroll_to with direction:"), refusal)
    }

    func testLaunchWithoutBundleIdNamesTheProfileKeys() {
        let refusal = MCPServer.requiredArgumentRefusal(tool: "ft_launch", args: [:]) ?? ""
        XCTAssertTrue(refusal.hasPrefix("bundleId is required"), refusal)
        XCTAssertTrue(refusal.contains("ios.bundleId"), refusal)
        XCTAssertTrue(refusal.contains("android.app"), refusal)
    }

    func testTapAcceptsLinkText() {
        XCTAssertNil(MCPServer.unknownArgumentRefusal(tool: "ft_tap", args: ["selector": "#terms", "linkText": "規約"]))
    }

    func testBatchLaunchWithABareArgumentIsRefusedByCategoryNotSyntax() async {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() }, recordSnapshot: { _, _, _ in })
        for line in ["launch com.example.app", "launchApp com.example.app", "clearAppData com.example.app"] {
            do {
                _ = try await server.call(tool: "ft_batch", args: ["steps": line])
                XCTFail("\(line) ran in a batch")
            } catch {
                let message = error.localizedDescription
                XCTAssertFalse(message.contains("could not parse"), "\(line): \(message)")
                XCTAssertTrue(message.contains("ft_batch does not run") || message.contains("does not run"), "\(line): \(message)")
            }
        }
    }

    func testNotationHintNamesAnIdWrittenAsALabel() {
        let snapshot = SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                        elements: [ElementInfo(ref: 1, type: "button", identifier: "nav_collapse",
                                                               label: "Collapse", value: nil, placeholder: nil,
                                                               enabled: true,
                                                               frame: FTRect(x: 0, y: 0, width: 50, height: 50), depth: 1)],
                                        truncatedCount: 0)
        let hint = MCPServer.notationHint("nav_collapse", in: snapshot)
        XCTAssertTrue(hint.contains("write #nav_collapse"), hint)
        XCTAssertFalse(MCPServer.notationHint("#nav_collapse", in: snapshot).contains("write #nav_collapse"))
    }

    func testClearAppDataDescriptionDoesNotClaimRunsResetData() {
        let description = MCPServer.toolDefinitions.first { $0["name"] as? String == "ft_clear_app_data" }?["description"] as? String ?? ""
        XCTAssertTrue(description.contains("runs do not reset app data"), description)
    }
}
