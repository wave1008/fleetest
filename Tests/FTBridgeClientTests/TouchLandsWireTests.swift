// in-app ブリッジの POST /touchlands の配線(InAppDriver → BridgeClient)と、答えられない相手で nil に畳むことの固定
import XCTest
@testable import FTBridgeClient
import FTCore

final class TouchLandsWireTests: XCTestCase {

    func testInAppDriverPostsThePointAndRefsAndDecodesTheAnswer() async throws {
        let stub = try RecordingStubServer(body: #"{"receiver":"HostingView","lands":[6],"unresolved":[]}"#)
        defer { stub.stop() }
        let driver = InAppDriver(repoRoot: URL(fileURLWithPath: NSTemporaryDirectory()), udid: "no-such-udid", port: stub.port)
        let answer = await driver.touchLands(x: 358, y: 744, refs: [6, 18, 19])
        XCTAssertEqual(answer, TouchLandsResponse(receiver: "HostingView", lands: [6], unresolved: []))
        XCTAssertEqual(stub.paths, ["POST /touchlands"])
        let body = try XCTUnwrap(stub.body(for: "POST /touchlands")?.data(using: .utf8))
        let sent = try JSONDecoder().decode(TouchLandsRequest.self, from: body)
        XCTAssertEqual(sent.refs, [6, 18, 19])
        XCTAssertEqual(sent.x, 358)
        XCTAssertEqual(sent.y, 744)
    }

    /// 経路を持たない相手(XCUITest ランナーの 404・通信断)は nil = 呼び手は断るまま
    func testNoAnswerIsNil() async {
        let driver = InAppDriver(repoRoot: URL(fileURLWithPath: NSTemporaryDirectory()), udid: "no-such-udid", port: 1)
        let answer = await driver.touchLands(x: 1, y: 1, refs: [1])
        XCTAssertNil(answer)
    }
}
