import XCTest
import FTCore
@testable import fleetest_mcp

/// ft_type の本文の文字数の上限(DSL の type と同じ判定。デバイスに触る前に断る)
final class FtTypeTextLimitTests: XCTestCase {

    private func message(forLength n: Int) async -> String? {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        do {
            _ = try await server.call(tool: "ft_type", args: ["ref": 1, "text": String(repeating: "a", count: n)])
            return nil
        } catch {
            return "\(error)"
        }
    }

    func testOverTheLimitIsRefusedWithTheSplitAdvice() async {
        let m = await message(forLength: BridgeAPI.maxTypeCharacters + 1)
        XCTAssertTrue(m?.contains("at most \(BridgeAPI.maxTypeCharacters)") == true, m ?? "no error")
    }

    func testExactlyAtTheLimitIsNotRefusedForLength() async {
        let m = await message(forLength: BridgeAPI.maxTypeCharacters)
        XCTAssertFalse(m?.contains("at most \(BridgeAPI.maxTypeCharacters)") == true, m ?? "")
    }
}
