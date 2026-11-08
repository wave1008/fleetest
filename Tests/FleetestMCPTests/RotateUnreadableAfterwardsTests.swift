// 37周目 ilocal F2: ft_terminate の後の ft_rotate が「no session」の失敗を返すのに端末は回っていて、次の ft_launch が横で起動した
// (回転は成功・その後の木の読みがセッション無しで 409)。回したことと、読めなかったことを分けて言う

import XCTest
@testable import FTCore
@testable import fleetest_mcp

final class RotateUnreadableAfterwardsTests: XCTestCase {
    func testRotationIsReportedEvenWhenTheTreeCannotBeRead() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        driver.failing = ["snapshot"]
        let result = try await server.call(tool: "ft_rotate", args: ["orientation": "landscape"])
        let text = try XCTUnwrap(result.first?["text"] as? String)
        XCTAssertTrue(text.hasPrefix("Rotated the device to landscape"), text)
        XCTAssertTrue(text.contains("could not be read"), text)
        XCTAssertTrue(driver.calls.contains { $0.hasPrefix("rotate") }, "\(driver.calls)")
    }
}
