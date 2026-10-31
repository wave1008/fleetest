// hideKeyboard の Return 案内・直近の木の覆い警告の純粋部分

import XCTest
import FTCore
@testable import fleetest_mcp

final class GestureFixesTests: XCTestCase {
    private func element(_ ref: Int, _ type: String, _ label: String, _ frame: FTRect) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: nil, label: label, value: nil, placeholder: nil,
                    enabled: true, frame: frame, depth: 1)
    }

    /// アプリが居ない(503)・セッションが無い(409)・届いたか不明のとき、Return で閉じる案内は出さない
    func testReturnKeyAdviceIsOmittedWhenNothingCanBeTyped() {
        XCTAssertTrue(MCPServer.returnKeyAdviceIsPointless(.badResponse(status: 503, body: "")))
        XCTAssertTrue(MCPServer.returnKeyAdviceIsPointless(.badResponse(status: 409, body: "")))
        XCTAssertFalse(MCPServer.returnKeyAdviceIsPointless(.badResponse(status: 422, body: "")))
        XCTAssertFalse(MCPServer.returnKeyAdviceIsPointless(nil))
    }

    /// 直近の木にアプリ内アラートがあれば、座標の操作・スワイプの応答に警告を足す。無ければ黙る
    func testLastTreeCoverWarningNamesAnAlert() {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        let back = element(1, "button", "背面", FTRect(x: 0, y: 0, width: 100, height: 40))
        let alert = element(2, "alert", "確認", FTRect(x: 40, y: 300, width: 320, height: 160))
        let tree = SnapshotResponse(sessionBundleID: "a", screen: screen, elements: [back, alert], truncatedCount: 0)
        XCTAssertTrue(MCPServer.lastTreeCoverWarning(tree).contains("Handle the alert first"))
        let plain = SnapshotResponse(sessionBundleID: "a", screen: screen, elements: [back], truncatedCount: 0)
        XCTAssertEqual(MCPServer.lastTreeCoverWarning(plain), "")
        XCTAssertEqual(MCPServer.lastTreeCoverWarning(nil), "")
    }

    /// 画面の中心を覆うオーバーレイの窓は警告する。隅のバナーだけなら黙る
    func testLastTreeCoverWarningNamesACentreOverlay() {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        var tree = SnapshotResponse(sessionBundleID: "a", screen: screen, elements: [], truncatedCount: 0)
        tree.overlayWindowFrames = [screen]
        XCTAssertTrue(MCPServer.lastTreeCoverWarning(tree).contains("overlay window"))
        tree.overlayWindowFrames = [FTRect(x: 0, y: 0, width: 400, height: 60)]
        XCTAssertEqual(MCPServer.lastTreeCoverWarning(tree), "")
    }
}
