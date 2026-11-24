// swipe の「このブリッジでは不可」ラッチは path の有無で分ける。path 付き(scrollFrame 指定)は in-app が
// 必ず 501 を返すので、共有すると1回撃っただけで path 無しの swipe まで XCUITest の実スワイプ化する
// (バウンス由来の flake)。path 付きどうしでは往復を省く。
// 指の下の容器の選び方(画面の根の全体を覆う要素には受理させない)は ScrollPointReach.mayAccept

import XCTest
@testable import FTCore

/// path 付きの swipe だけを 501 で断り、path 無しは受ける(in-app の自前描画を模す)
private final class SwipeRecordingDriver: AppDriver {
    private(set) var plainSwipes = 0
    private(set) var pathSwipes = 0
    let rejectsPath: Bool

    init(rejectsPath: Bool) { self.rejectsPath = rejectsPath }

    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {
        if path != nil {
            if rejectsPath { throw DriverError.badResponse(status: 501, body: "path swipe is not supported") }
            pathSwipes += 1
        } else {
            plainSwipes += 1
        }
    }

    func swipe(_ direction: FTSwipeDirection) async throws { plainSwipes += 1 }
    /// swipe の応答に載った注記を模す(読むと消える = AndroidDriver の pendingTypeNote と同じ一回読みの控え)
    var noteAfterSwipe: String?
    var lastActionNote: String? {
        defer { noteAfterSwipe = nil }
        return noteAfterSwipe
    }
    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                         elements: [], truncatedCount: 0)
    }
    func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse { try await snapshot() }
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws -> String? { nil }
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}

final class SwipeFallbackLatchTests: XCTestCase {

    private let path = FTSwipePath(fromX: 200, fromY: 600, toX: 200, toY: 200)

    /// path 付きが XCUITest へ落ちても、その後の path 無しは in-app のまま撃つ
    func testPathSwipeFallbackDoesNotMovePlainSwipesToXCUITest() async throws {
        let primary = SwipeRecordingDriver(rejectsPath: true)
        let fallback = SwipeRecordingDriver(rejectsPath: false)
        let executor = StepExecutor(driver: primary, typeDriver: fallback, isAndroid: false, tunables: RunTunables())
        var phase = StepExecutor.PhaseAccumulator()
        _ = try await executor.swipeWithFallback(.up, path: path, phase: &phase)
        _ = try await executor.swipeWithFallback(.up, phase: &phase)
        XCTAssertEqual(fallback.pathSwipes, 1, "path 付きは XCUITest へ落ちる")
        XCTAssertEqual(primary.plainSwipes, 1, "path 無しは in-app のまま")
        XCTAssertEqual(fallback.plainSwipes, 0, "path 無しを XCUITest の実スワイプへ回した")
    }

    /// path 付きどうしでは、2回目から in-app を経由せず直接 XCUITest へ
    func testPathSwipeLatchSkipsTheRoundTripForLaterPathSwipes() async throws {
        let primary = SwipeRecordingDriver(rejectsPath: true)
        let fallback = SwipeRecordingDriver(rejectsPath: false)
        let executor = StepExecutor(driver: primary, typeDriver: fallback, isAndroid: false, tunables: RunTunables())
        var phase = StepExecutor.PhaseAccumulator()
        _ = try await executor.swipeWithFallback(.up, path: path, phase: &phase)
        let secondWentToFallback = try await executor.swipeWithFallback(.up, path: path, phase: &phase)
        XCTAssertTrue(secondWentToFallback)
        XCTAssertEqual(fallback.pathSwipes, 2)
    }

    /// 画面の根の全体を覆う要素には受理させない(Flutter の意味木の根が横の scroll を受理してカルーセルを動かしていた)
    func testElementCoveringTheWholeRootMayNotAccept() {
        XCTAssertFalse(ScrollPointReach.mayAccept(frame: FTRect(x: 0, y: 0, width: 402, height: 874),
                                                  rootWidth: 402, rootHeight: 874))
        XCTAssertFalse(ScrollPointReach.mayAccept(frame: FTRect(x: 0.5, y: 0, width: 401.6, height: 873.4),
                                                  rootWidth: 402, rootHeight: 874), "1pt の丸めは根と同じ扱い")
    }

    /// 根より小さい容器(画面中央の縦リスト)は受理してよい
    func testInnerContainerMayAccept() {
        XCTAssertTrue(ScrollPointReach.mayAccept(frame: FTRect(x: 16, y: 226, width: 370, height: 470),
                                                 rootWidth: 402, rootHeight: 874))
    }

    /// swipe の応答の注記(/scrollAction の「入れ子の容器へ送った」等)は撃った直後に消費する
    /// (ドライバの控えに残すと次の tap/type の説明に付く = executeDirectType の doc の罠)。同じ注記は1回だけ
    func testSwipeBridgeNoteIsConsumedRightAfterTheSwipe() async throws {
        let primary = SwipeRecordingDriver(rejectsPath: false)
        let fallback = SwipeRecordingDriver(rejectsPath: false)
        let executor = StepExecutor(driver: primary, typeDriver: fallback, isAndroid: true, tunables: RunTunables())
        var phase = StepExecutor.PhaseAccumulator()
        primary.noteAfterSwipe = "scrolled the nested list instead"
        _ = try await executor.swipeWithFallback(.up, phase: &phase)
        XCTAssertEqual(executor.swipeBridgeNoteThisStep, "scrolled the nested list instead")
        XCTAssertNil(primary.lastActionNote, "撃った直後に消費する(次の操作へ持ち越さない)")
        primary.noteAfterSwipe = "scrolled the nested list instead"
        _ = try await executor.swipeWithFallback(.up, phase: &phase)
        XCTAssertEqual(executor.swipeBridgeNoteThisStep, "scrolled the nested list instead", "同じ注記は繰り返さない")
    }
}
