// 版ズレは呼び出しごとに門を掛ける(控えのドライバで引く前): 許可の無い呼び出しは今のブリッジで測り直して、まだ食い違えば断り、
// 直っていれば通す。許可のある呼び出しは毎回警告する

import XCTest
import FTCore
@testable import fleetest_mcp

final class VersionSkewEachCallGateTests: XCTestCase {
    private var cached: FakeDriver!
    private var server: MCPServer!
    private let key = MCPServer.sessionKey([:])

    override func setUp() {
        super.setUp()
        cached = FakeDriver()
        cached.statusResponse = StatusResponse(ready: true, device: "iPhone 17", osVersion: "27.0",
                                               sessionBundleID: "com.example.app",
                                               protocolVersion: BridgeAPI.bridgeProtocolVersion - 1)
        let fresh = FakeDriver()
        server = MCPServer(write: { _ in }, makeDriver: { _ in fresh }, recordSnapshot: { _, _, _ in })
        server.drivers[key] = cached
        server.versionSkew[key] = "bridge protocol mismatch: recorded when the driver was made."
    }

    private func text(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    func testCallWithoutPermissionIsRefusedWhileTheBridgeStillDiffers() async throws {
        do {
            _ = try await server.call(tool: "ft_snapshot", args: [:])
            XCTFail("a skewed session must refuse a call without allowVersionSkew")
        } catch {
            XCTAssertTrue("\(error)".contains("allowVersionSkew: true"), "\(error)")
            XCTAssertTrue("\(error)".contains("OLDER"), "今のブリッジで測り直した文を返す: \(error)")
        }
        XCTAssertNil(server.versionSkew[key])
        XCTAssertNil(server.drivers[key], "断ったら控えを捨てる")
    }

    func testFixedBridgeIsNotRefusedFromTheStaleRecord() async throws {
        cached.statusResponse = StatusResponse(ready: true, device: "iPhone 17", osVersion: "27.0",
                                               sessionBundleID: "com.example.app",
                                               protocolVersion: BridgeAPI.bridgeProtocolVersion)
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        XCTAssertNil(server.versionSkew[key])
    }

    func testEveryPermittedCallCarriesTheWarning() async throws {
        for _ in 0..<2 {
            let reply = text(try await server.call(tool: "ft_snapshot", args: ["allowVersionSkew": true]))
            XCTAssertTrue(reply.contains("⚠️ allowVersionSkew: proceeding despite a bridge/host mismatch"), reply)
        }
    }
}
