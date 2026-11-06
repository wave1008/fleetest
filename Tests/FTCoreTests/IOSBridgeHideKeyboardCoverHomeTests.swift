// RN の resign で hideKeyboard・手前の窓に覆われて落とした要素の申告・/home の対象 bundle ID と
// 押し直しの打ち切り)。in-app の dylib とランナーは swift test でリンクされないので、配線はソースを走査して守る。

import XCTest
@testable import FTCore

final class IOSBridgeHideKeyboardCoverHomeTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func body(of marker: String, in src: String, length: Int = 1800) throws -> String {
        let start = try XCTUnwrap(src.range(of: marker), "\(marker) が見つかりません")
        return String(src[start.upperBound...].prefix(length))
    }

    // MARK: RN の resign

    func testResignIsLimitedToReactNativeInputsByClassName() throws {
        let m = try source("InAppBridge/Sources/InAppInput.m")
        let fn = try body(of: "BOOL FTResignReactNativeTextInput(void) {", in: m, length: 700)
        XCTAssertTrue(fn.contains("@\"RCTUITextField\"") && fn.contains("@\"RCTUITextView\""))
        XCTAssertTrue(fn.contains("[fr resignFirstResponder]"))
        XCTAssertFalse(fn.contains("textFieldShouldReturn") || fn.contains("EditingDidEndOnExit"),
                       "resign は Enter(submit)を撃たない手")
    }

    func testInAppHideKeyboardResignsThenChecksKeyboardAndStillRefusesOthersWith501() throws {
        let s = try source("InAppBridge/Sources/InAppBridge.swift")
        let fn = try body(of: "private func handleHideKeyboard() throws -> InAppHTTPServer.Response {", in: s, length: 1300)
        let resign = try XCTUnwrap(fn.range(of: "FTResignReactNativeTextInput()"))
        let check = try XCTUnwrap(fn.range(of: "Self.keyboardIsVisible()"))
        let refuse = try XCTUnwrap(fn.range(of: "status: 501"))
        XCTAssertLessThan(resign.lowerBound, check.lowerBound, "閉じた後に枠で確かめる")
        XCTAssertLessThan(resign.lowerBound, refuse.lowerBound)
        XCTAssertTrue(fn.contains("InAppError(500"), "閉じなかったのに成功と言わない")
    }

    // MARK: 手前の窓の申告

    func testFrontWindowCoverIsReportedInSeparateFieldNotOverlayWindowFrames() throws {
        let snap = try source("InAppBridge/Sources/InAppSnapshot.swift")
        XCTAssertTrue(snap.contains("tally.record(covering)"))
        XCTAssertTrue(snap.contains("frontWindowCover: tally.result"))
        let bridge = try source("InAppBridge/Sources/InAppBridge.swift")
        XCTAssertTrue(bridge.contains("coveredByFrontWindow: base.frontWindowCover"))
        XCTAssertFalse(bridge.contains("overlayWindowFrames:"), "in-app は overlayWindowFrames(タップが吸われる帯)を申告しない")
    }

    func testFrontWindowCoverWireShapeRoundTrips() throws {
        let cover = FrontWindowCover(droppedCount: 7, frames: [FTRect(x: 0, y: 0, width: 402, height: 874)])
        let response = SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                        elements: [], truncatedCount: 0, coveredByFrontWindow: cover)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(SnapshotResponse.self, from: data)
        XCTAssertEqual(decoded.coveredByFrontWindow, cover)
        XCTAssertNil(decoded.overlayWindowFrames)
    }

    // MARK: /home の対象

    func testHomeRequestCarriesBundleIDAndClientSendsIt() throws {
        let data = try JSONEncoder().encode(HomeRequest(bundleID: "com.example.app"))
        XCTAssertEqual(try JSONDecoder().decode(HomeRequest.self, from: data).bundleID, "com.example.app")
        XCTAssertNil(try JSONDecoder().decode(HomeRequest.self, from: Data("{}".utf8)).bundleID)
        XCTAssertTrue(try source("Sources/FTBridgeClient/BridgeClient.swift")
            .contains("post(\"/home\", body: HomeRequest(bundleID: bundleID)"))
        XCTAssertTrue(try source("Sources/FTBridgeClient/AppAttachDriver.swift")
            .contains("try await client.home(bundleID: bundleID)"))
    }

    func testRunnerReadsOwnAppAlertFromHomeTargetAndStopsRetryingOnInterruption() throws {
        let r = try source("Runner/FleetestRunnerUITests/BridgeRouter.swift")
        let own = try body(of: "private func blockedByOwnAppAlert() -> Bool {", in: r, length: 300)
        XCTAssertTrue(own.contains("app ?? homeTargetApp"), "セッションが無くても対象の bundle ID で読む")
        let home = try body(of: "private func handleHome(_ body: Data)", in: r, length: 6000)
        XCTAssertTrue(home.contains("decode(HomeRequest.self, body)"))
        let send = try XCTUnwrap(home.range(of: "sendHome(sb, attempt: attempt)"))
        let stop = try XCTUnwrap(home.range(of: "if InterruptionGuard.shared.hasBlocked { break }"))
        let verifiable = try XCTUnwrap(home.range(of: "guard verifiable, let app else { break }"))
        XCTAssertLessThan(send.lowerBound, stop.lowerBound)
        XCTAssertLessThan(stop.lowerBound, verifiable.lowerBound, "押し直しの前に打ち切る")
        // 422 の名指しは handleHome を出た後に handle が組む = handleHome の中で対象を消すと読めない(iPhone 13 で「system alert」のまま)
        XCTAssertFalse(home.contains("defer { homeTargetApp = nil }"), "handleHome を出る時に対象を消している")
        let entry = try body(of: "func handle(_ request: BridgeHTTPServer.Request) -> BridgeHTTPServer.Response {", in: r, length: 400)
        XCTAssertTrue(entry.contains("homeTargetApp = nil"), "要求の入口で対象を消していない")
    }
}
