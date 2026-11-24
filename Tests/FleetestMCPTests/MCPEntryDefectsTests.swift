// MCP 入口の欠陥の回帰: オブジェクトでない `arguments`・診断の adb を協調スレッドプールに載せない形。

import XCTest
@testable import fleetest_mcp

final class MCPEntryDefectsTests: XCTestCase {

    private func respond(toToolsCall params: [String: Any]) async throws -> [String: Any] {
        let written = LockedData()
        let server = MCPServer(write: { written.append($0) }, makeDriver: { _ in FakeDriver() },
                               recordSnapshot: { _, _, _ in })
        await server.handle(["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": params])
        let line = try XCTUnwrap(written.string.split(separator: "\n").first, "応答が1行も書かれていない")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    /// 文字列・配列・数値の arguments は `[:]` に畳まず、同じ id で isError を返す(何も実行しない)。
    /// 変異: `handle` の `nonObjectArgumentsRefusal` の分岐を外す(`?? [:]` だけに戻す)と、ft_snapshot が実行されて落ちる
    func testNonObjectArgumentsAreRefusedWithTheSameID() async throws {
        let bad: [Any] = ["{\"x\":1}", [1, 2], 5, true]
        for raw in bad {
            let response = try await respond(toToolsCall: ["name": "ft_snapshot", "arguments": raw])
            XCTAssertEqual(response["id"] as? Int, 7)
            let result = try XCTUnwrap(response["result"] as? [String: Any], "\(response)")
            XCTAssertEqual(result["isError"] as? Bool, true, "\(raw)")
            let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            XCTAssertTrue(text.contains("arguments must be a JSON object"), text)
        }
    }

    func testMissingOrNullArgumentsAreStillAccepted() {
        XCTAssertNil(MCPServer.nonObjectArgumentsRefusal(nil))
        XCTAssertNil(MCPServer.nonObjectArgumentsRefusal(NSNull()))
        XCTAssertNil(MCPServer.nonObjectArgumentsRefusal([String: Any]()))
        XCTAssertNotNil(MCPServer.nonObjectArgumentsRefusal([Any]()))
    }

    /// adb(pidof・logcat)はプールの外。変異: `runOffCooperativePool` を外して同期呼びに戻す / `async` を外すと落ちる
    func testProcessEvidenceQueryRunsOffTheCooperativePool() throws {
        let code = try MCPServerSourceText.combined()
        guard let start = code.range(of: "func androidProcessEvidenceForSwitch(") else {
            return XCTFail("関数が見つからない")
        }
        let body = String(code[start.lowerBound...].prefix(1800))
        XCTAssertTrue(body.contains("args: [String: Any]) async\n"), "async 関数であること")
        XCTAssertTrue(body.contains("runOffCooperativePool"), "adb をプールの外で払う")
        XCTAssertFalse(code.contains("processEvidence: androidProcessEvidenceForSwitch("),
                       "await 無しの呼び出しが残っている(同期のまま adb を払う)")
    }
}

private final class LockedData: @unchecked Sendable {
    // 不変条件: data への全アクセスは lock の中
    private let lock = NSLock()
    private var data = Data()
    func append(_ more: Data) { lock.lock(); data.append(more); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
