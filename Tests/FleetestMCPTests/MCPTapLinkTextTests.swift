// ft_tap(selector, linkText:): 段落の中のリンクの語を、DSL と同じ `LinkTextLocator` で決めた位置で押し、
// 下書きに tap(selector, linkText:) を残す。木に無い語は fmAndVision: true のときだけ OCR(既定は撃たずに断る)

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPTapLinkTextTests: XCTestCase {

    private func element(_ ref: Int, id: String?, label: String, frame: FTRect, depth: Int) -> ElementInfo {
        ElementInfo(ref: ref, type: "staticText", identifier: id, label: label, value: nil, placeholder: nil,
                    enabled: true, frame: frame, depth: depth)
    }

    private func make(withLinkChild: Bool) -> (MCPServer, FakeDriver) {
        let fake = FakeDriver()
        fake.foregroundBundleID = "com.example.app"
        var elements = [element(1, id: "para", label: "続行すると利用規約とプライバシーに同意します",
                                frame: FTRect(x: 0, y: 100, width: 300, height: 60), depth: 1)]
        if withLinkChild {
            elements.append(element(2, id: nil, label: "利用規約", frame: FTRect(x: 100, y: 110, width: 60, height: 20), depth: 2))
        }
        fake.snapshotResponse.elements = elements
        let server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
        return (server, fake)
    }

    func testLinkInTheTreeIsPressedAtItsCentreAndDraftedWithLinkText() async throws {
        let (server, fake) = make(withLinkChild: true)
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = try await server.call(tool: "ft_tap", args: ["selector": "#para", "linkText": "利用規約"])
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
        XCTAssertTrue(fake.calls.contains { $0.hasPrefix("tap(x:130.0,y:120.0)") }, "\(fake.calls)")
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("tap(ref:") }, "段落の中心を押した: \(fake.calls)")
        XCTAssertTrue(text.contains("located by tree"), text)
        let draft = try await server.call(tool: "ft_draft_scenario", args: [:])
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
        XCTAssertTrue(draft.contains("linkText: \"利用規約\""), draft)
    }

    func testTextNotInTheTreeIsRefusedWithoutOCRByDefault() async throws {
        let (server, fake) = make(withLinkChild: false)
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        do {
            _ = try await server.call(tool: "ft_tap", args: ["selector": "#para", "linkText": "利用規約"])
            XCTFail("木に無い語を OCR なしで押した")
        } catch let error as MCPError {
            XCTAssertTrue(error.message.contains("fmAndVision: true"), error.message)
            XCTAssertTrue(error.message.contains("tap(selector, linkText: \"利用規約\")"), error.message)
        }
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("tap(") || $0.hasPrefix("screenshot") }, "\(fake.calls)")
    }

    func testLinkTextWithCoordinatesIsRefused() async throws {
        let (server, fake) = make(withLinkChild: true)
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        do {
            _ = try await server.call(tool: "ft_tap", args: ["x": 10, "y": 10, "linkText": "利用規約"])
            XCTFail("座標と linkText を併用できた")
        } catch let error as MCPError {
            XCTAssertTrue(error.message.contains("not x/y"), error.message)
        }
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("tap(") }, "\(fake.calls)")
    }
}
