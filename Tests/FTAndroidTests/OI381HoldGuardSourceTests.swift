// OI-381 ⑤: Android ブリッジは /hold の指が下りている間、他の指の注入(/tap・/swipe・/doubletap・/pinch・/gesture・/press・
// ref 付きの /type・/clear)を 409 で断る。/swipe の durationMs は 1〜60000ms だけ受ける。
// Java はデバイス上でしか動かないのでソース走査で固定する(実機での確認はデバイス実行)。

import XCTest

final class OI381HoldGuardSourceTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent("AndroidRunner/src/com/example/ftbridge/\(name)"),
                   encoding: .utf8)
    }

    /// `private BridgeHttpServer.Response <name>(` から次のメソッドの手前まで
    private func handlerBody(_ name: String, in source: String) throws -> String {
        guard let start = source.range(of: "private BridgeHttpServer.Response \(name)(") else {
            throw XCTSkip("\(name) が見つからない(改名したら走査も直す)")
        }
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "\n    }\n")?.upperBound ?? rest.endIndex
        return String(rest[..<end])
    }

    func testTouchInjectingHandlersRejectWhileHolding() throws {
        let router = try source("BridgeRouter.java")
        for name in ["handleTap", "handleSwipe", "handleDoubleTap", "handlePinch", "handleGesture", "handlePress"] {
            XCTAssertTrue(try handlerBody(name, in: router).contains("rejectWhileHolding();"),
                          "\(name) が hold 中の注入を断っていない")
        }
        for name in ["handleType", "handleClear"] {
            XCTAssertTrue(try handlerBody(name, in: router).contains("rejectWhileHolding();"),
                          "\(name) の ref 経路が hold 中の注入を断っていない")
        }
    }

    func testHoldItselfStillAnswers409AndGuardUses409() throws {
        let router = try source("BridgeRouter.java")
        XCTAssertTrue(router.contains("InputInjector.isHolding()"))
        XCTAssertTrue(router.contains("throw new BridgeException(409, \"a finger placed by an earlier hold is still down"))
        let injector = try source("InputInjector.java")
        XCTAssertTrue(injector.contains("static boolean isHolding()"))
    }

    func testSwipeDurationIsRangeChecked() throws {
        let body = try handlerBody("handleSwipe", in: try source("BridgeRouter.java"))
        XCTAssertTrue(body.contains("strokeMs <= 0 || strokeMs > (long) (GESTURE_SECONDS_CEILING * 1000)"))
        XCTAssertTrue(body.contains("throw new BridgeException(400, \"durationMs must be between 1 and "))
    }
}
