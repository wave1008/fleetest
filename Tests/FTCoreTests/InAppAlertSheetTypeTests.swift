// in-app の木が UIAlertController の根の view を preferredStyle で `alert` / `sheet` に分けることの固定。
// in-app の dylib は swift test でリンクされないのでソースを走査する(XCUITest ブリッジの型の写像と同じ語彙)。

import XCTest

final class InAppAlertSheetTypeTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testAlertControllerRootIsSplitByPreferredStyle() throws {
        let s = try source("InAppBridge/Sources/InAppSnapshot.swift")
        let start = try XCTUnwrap(s.range(of: "static func alertContainerType("))
        let body = String(s[start.upperBound...].prefix(400))
        XCTAssertTrue(body.contains("case .alert: return .alert"))
        XCTAssertTrue(body.contains("case .actionSheet: return .sheet"))
        XCTAssertFalse(body.contains("modalPresentationStyle"), "表示の形で分けると iPhone の confirmationDialog(.popover と申告)で容器が消える")
        XCTAssertTrue(s.contains("controller.preferredStyle"), "根の view は preferredStyle を見て分ける")
        XCTAssertTrue(s.contains("case .sheet: return \"Sheet\""), "XCUITest ブリッジと同じ型名")
        XCTAssertTrue(s.contains("case .navigationBar, .tabBar, .alert, .sheet, .webView:"), "sheet は id 無しでも木に残す")
    }

    func testXCUITestBridgeNamesSheetTheSame() throws {
        let r = try source("Runner/FleetestRunnerUITests/BridgeRouter+Snapshot.swift")
        XCTAssertTrue(r.contains("case .sheet: return \"Sheet\""))
    }
}
