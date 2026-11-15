// OI-234 の測る口: 蘇生の記録の各行に、蘇生を始めてからの経過秒を前置する(枠 60 秒のどこを何が使ったかを後から読む)

import XCTest
@testable import FTAndroid

final class ReviveLogStampTests: XCTestCase {

    func testLinesCarryTheSecondsSinceTheReviveStarted() {
        XCTAssertEqual(ProfileWorkerFactory.reviveStamped("✅ bridge ready", elapsed: .milliseconds(12_345)),
                       "[revive +12.3s] ✅ bridge ready")
        XCTAssertEqual(ProfileWorkerFactory.reviveStamped("x", elapsed: .zero), "[revive +0.0s] x")
    }

    /// 配線: 蘇生の iOS の経路が書く行(供給の log と枠切れの行)は全部、経過秒を付ける口を通る
    func testTheIOSRevivePathWritesThroughTheStampedSink() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FTAndroid/ProfileWorkerFactory.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "public static func buildWorker(forLogicalName"))
        let end = try XCTUnwrap(source.range(of: "if let device = resolved.androidDevices", range: start.upperBound..<source.endIndex))
        let body = source[start.upperBound..<end.lowerBound]
        XCTAssertTrue(body.contains("Self.reviveStamped(line"), "蘇生の記録が経過秒を付ける口を通っていない")
        XCTAssertFalse(body.contains("SerializedSink(log)\n            let budgetExpired"), "経過秒の無い口へ戻った")
    }
}
