// 端末のブリッジが期待より新しい Android を、MCP は `allowVersionSkew: true` のときだけ使う。
// 許可は AndroidDriver へ明示で渡す(既定 false = DSL・CLI は拒否のまま)。

import XCTest
import FTBridgeClient
@testable import fleetest_mcp

final class AndroidNewerBridgeSkewTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func compactCode(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
            .split(separator: "\n").filter { !$0.drop { $0 == " " }.hasPrefix("//") }.joined()
            .filter { !$0.isWhitespace }
    }

    /// 両経路(直接・profile)が同じ入口を通り、allowVersionSkew を許可として渡す。
    /// 変異: 入口を素の `AndroidDriver(serial:)` に戻す / 許可を常に false・true にすると落ちる
    func testAndroidPathsPassAllowVersionSkewThrough() throws {
        let source = try compactCode("Sources/fleetest-mcp/MCPServer+Driver.swift")
        XCTAssertEqual(source.components(separatedBy: "androidDriver(serial:serial,key:key,args:args)").count - 1, 2,
                       "直接・profile の両方が androidDriver(...) を通っていない")
        XCTAssertEqual(source.components(separatedBy: "AndroidDriver(serial:").count - 1, 1,
                       "androidDriver 以外が AndroidDriver(serial:) を直に作っている")
        XCTAssertTrue(source.contains("letallowSkew=args[\"allowVersionSkew\"]as?Bool==true"))
        XCTAssertTrue(source.contains("acceptsNewerInstalledBridge:allowSkew"))
        XCTAssertTrue(source.contains("pendingWarnings[key,default:[]].append(Self.skewOverrideWarning(text))"))
    }

    /// 許可を渡してよいのは MCP だけ(DSL・CLI・供給は既定の false)
    func testNoOtherCallerAcceptsANewerBridge() throws {
        let fm = FileManager.default
        let sources = Self.repoRoot.appendingPathComponent("Sources")
        var offenders: [String] = []
        for case let url as URL in fm.enumerator(at: sources, includingPropertiesForKeys: nil)! where url.pathExtension == "swift" && url.lastPathComponent != "MCPServer+Driver.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("acceptsNewerInstalledBridge: true") || text.contains("acceptsNewerInstalledBridge: allow") {
                offenders.append(url.lastPathComponent)
            }
        }
        XCTAssertTrue(offenders.isEmpty, "MCP 以外が新しいブリッジの使用を許可している: \(offenders)")
    }

    func testRefusalAddendumNamesTheEscapeHatch() {
        XCTAssertTrue(MCPServer.androidNewerBridgeAddendum.contains("allowVersionSkew: true"))
    }

    func testSkewWarningCarriesBothVersionsAndTheSharedPrefix() {
        let text = MCPServer.androidNewerBridgeSkew(BridgeVersionSkew(running: 140, expected: 136))
        XCTAssertTrue(text.contains("v140"), text)
        XCTAssertTrue(text.contains("v136"), text)
        XCTAssertTrue(MCPServer.skewOverrideWarning(text).hasPrefix("⚠️ allowVersionSkew:"))
    }
}
