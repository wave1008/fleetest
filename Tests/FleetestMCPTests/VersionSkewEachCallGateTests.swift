// 版ズレは呼び出しごとに門を掛ける: 一度 allowVersionSkew: true で作ったドライバが控えに残っても、許可の無い後の呼び出しは断り、
// 許可のある呼び出しは毎回警告する(生成時の1回だけだと、後の呼び出しが黙って新しい/古いブリッジを使い続けた)

import XCTest
import FTCore
@testable import fleetest_mcp

final class VersionSkewEachCallGateTests: XCTestCase {
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        let fake = FakeDriver()
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
        server.versionSkew[MCPServer.sessionKey([:])] = "bridge protocol mismatch: the bridge is NEWER (v9 > v8)."
    }

    private func text(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    func testCallWithoutPermissionIsRefusedAndForgetsTheSkew() async throws {
        do {
            _ = try await server.call(tool: "ft_snapshot", args: [:])
            XCTFail("a skewed session must refuse a call without allowVersionSkew")
        } catch {
            XCTAssertTrue("\(error)".contains("allowVersionSkew: true"), "\(error)")
        }
        XCTAssertNil(server.versionSkew[MCPServer.sessionKey([:])], "断ったら控えを捨てる(次の生成でもう一度測る)")
    }

    func testEveryPermittedCallCarriesTheWarning() async throws {
        for _ in 0..<2 {
            let reply = text(try await server.call(tool: "ft_snapshot", args: ["allowVersionSkew": true]))
            XCTAssertTrue(reply.contains("⚠️ allowVersionSkew: proceeding despite a bridge/host mismatch"), reply)
        }
    }
}
