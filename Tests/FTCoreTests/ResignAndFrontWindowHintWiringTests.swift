// iOS の RN はキーボードを閉じる前に in-app の resign を試す・手前の窓が要素を落とした木の解決失敗は窓を名指す。

import XCTest
@testable import FTCore

final class ResignAndFrontWindowHintWiringTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func snapshot(cover: FrontWindowCover?) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "app", screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                         elements: [], truncatedCount: 0, coveredByFrontWindow: cover)
    }

    func testHintNamesTheFrontWindowAndDoesNotSuggestWaiting() throws {
        let hint = try XCTUnwrap(StepExecutor.frontWindowCoverHint(snapshot(cover: FrontWindowCover(
            droppedCount: 7, frames: [FTRect(x: 20, y: 300, width: 362, height: 200)]))))
        XCTAssertTrue(hint.contains("(20,300 362x200)"))
        XCTAssertTrue(hint.contains("covers 7 element(s)"))
        XCTAssertTrue(hint.contains("waiting will not bring"))
    }

    func testNoHintWithoutTheReport() {
        XCTAssertNil(StepExecutor.frontWindowCoverHint(snapshot(cover: nil)))
        XCTAssertNil(StepExecutor.frontWindowCoverHint(snapshot(cover: FrontWindowCover(droppedCount: 0, frames: []))))
    }

    func testNotFoundMessagePrefersTheFrontWindowHintOverTheWaitHint() throws {
        let src = try source("Sources/FTCore/StepExecutor+Actions.swift")
        XCTAssertTrue(src.contains("(leftHint ?? Self.frontWindowCoverHint(hintSnapshot)\n"
            + "                            ?? (Self.waitHintAfterSearch("))
    }

    func testReactNativeTriesResignBeforeTappingAboveTheKeyboard() throws {
        let src = try source("Sources/FTCore/StepExecutor+DirectActions.swift")
        guard let body = src.range(of: "func closeKeyboardByTappingOutside(") else { return XCTFail("関数が無い") }
        let head = String(src[body.upperBound...].prefix(300))
        XCTAssertTrue(head.contains("if uiFramework == .reactNative, let closed = try await closeReactNativeKeyboardByResign("),
                      "空きを叩く前に RN の resign を試していない")
    }
}
