// in-app ブリッジの座標の tap は直近の /snapshot の表から要素を選ぶので、撃つ前に木を読み直すことの固定
import XCTest
@testable import FTBridgeClient
import FTCore

final class InAppDriverCoordinateTapTests: XCTestCase {

    /// 遷移の後に読まずに撃つと前の画面の表から選び、✅ のまま何も押さない。撃つ前に /snapshot を1回撃つ
    func testCoordinateTapReadsTheTreeBeforeTapping() async throws {
        // 1つの本文で /snapshot(SnapshotResponse)と /tap(OKResponse)の両方に答える(余分な欄は読み飛ばされる)
        let stub = try RecordingStubServer(
            body: #"{"ok":true,"screen":{"x":0,"y":0,"width":402,"height":874},"elements":[],"truncatedCount":0,"safeAreaTop":{"measured":false}}"#)
        defer { stub.stop() }
        let driver = InAppDriver(repoRoot: URL(fileURLWithPath: NSTemporaryDirectory()), udid: "no-such-udid", port: stub.port)
        try await driver.tap(x: 358, y: 744)
        let sent = stub.paths.filter { $0.hasPrefix("GET /snapshot") || $0.hasPrefix("POST /tap") }
        XCTAssertEqual(sent.map { $0.split(separator: "?")[0] }, ["GET /snapshot", "POST /tap"], "\(stub.paths)")
    }
}
