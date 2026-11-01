// OI-96: スワイプ/ドラッグが届いた後の読み取りの失敗を「未送信」と読ませない。
// 守るもの: ①接続拒否・notDelivered は届いたか不明の側へ倒れる ②他の case はそのまま
// ③ステップの出口が使い、スワイプ/ドラッグの入口 6 箇所が立てる(配線)。

import XCTest
@testable import FTCore

final class DriverErrorDeliveryAttributionTests: XCTestCase {
    private let context = DriverErrorContext(bridge: .iosXCUITest, physicalDevice: false)

    func testRefusedReadAfterDeliveredGestureBecomesDeliveryUnknown() {
        let refused = DriverError.bridgeConnectionRefused(context: context, detail: "refused")
        XCTAssertFalse(refused.deliveryIsUnknown)
        let attributed = refused.afterDeliveredGesture()
        XCTAssertTrue(attributed.deliveryIsUnknown)
        XCTAssertTrue((attributed.errorDescription ?? "").contains("earlier gesture of this step had already been delivered"))
        XCTAssertTrue((attributed.errorDescription ?? "").contains("refused"), "元の失敗の文を残す")
    }

    func testNotDeliveredReadAfterDeliveredGestureBecomesDeliveryUnknown() {
        let notDelivered = DriverError.notDelivered(context: context, detail: "adb down")
        XCTAssertFalse(notDelivered.deliveryIsUnknown)
        XCTAssertTrue(notDelivered.afterDeliveredGesture().deliveryIsUnknown)
    }

    func testOtherCasesAreUnchanged() {
        let unchanged: [DriverError] = [
            .bridgeUnreachable(context: context, detail: "timeout"),
            .deliveryUnknown(context: context, detail: "grpc"),
            .badResponse(status: 422, body: "x"),
            .bridgeIdentityMismatch("other device"),
            .staleRef(detail: "moved"),
            .systemAlertBlocked(detail: "alert"),
        ]
        for error in unchanged {
            XCTAssertEqual(error.afterDeliveredGesture().errorDescription, error.errorDescription)
            XCTAssertEqual(error.afterDeliveredGesture().deliveryIsUnknown, error.deliveryIsUnknown)
        }
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// 出口が帰属を通し、入口が立て、ステップの頭で降ろす。どれかが抜けると「未送信」が復活する
    func testExecutorWiring() throws {
        let executor = try source("Sources/FTCore/StepExecutor.swift")
        XCTAssertTrue(executor.contains("gestureDeliveredThisStep ? $0.afterDeliveredGesture() : $0"))
        XCTAssertTrue(executor.contains("gestureDeliveredThisStep = false"), "ステップの頭で降ろす")
        let settle = try source("Sources/FTCore/StepExecutor+Settle.swift")
        XCTAssertEqual(settle.components(separatedBy: "gestureDeliveredThisStep = true").count - 1, 6,
                       "dragWithFallback の3経路 + swipeWithFallback の3経路")
    }
}
