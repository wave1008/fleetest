import XCTest
@testable import FTCore

/// 対象外で終わった item の回し直し(DR-214)のキュー側。回し直しは `avoidedLane` の優先でなく**除外**として効く
final class ScenarioQueueNotApplicableTests: XCTestCase {
    private func item(_ id: String, placement: ClassPlacement? = nil) -> ScenarioRunItem {
        ScenarioRunItem(info: ScenarioInfo(id: id, title: id, platform: "ios", placement: placement))
    }
    /// 待ちが解けない退行でテストが止まらず落ちるための上限(期待どおりなら 0.1〜0.3 秒で返る)
    private static func deadline(_ seconds: Double = 5) -> @Sendable () async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        return { Date() > end }
    }

    func testHandOnGoesToTheUntriedLaneNotBackToTheDeclaringOne() async {
        let s1 = item("S1")
        let queue = ScenarioQueue([s1])
        await queue.laneJoined("duo")
        await queue.laneJoined("pro")
        let first = await queue.next(lane: "pro", shouldStop: Self.deadline())
        XCTAssertEqual(first?.info.id, "S1")
        let verdict = await queue.noteNotApplicable(s1, lane: "pro", reason: "fold")
        XCTAssertEqual(verdict, .handOn)
        // 宣言したレーンが先に聞いても渡さない(duo が取るまで待つ)
        async let forPro = queue.next(lane: "pro", shouldStop: Self.deadline())
        try? await Task.sleep(for: .milliseconds(100))
        let forDuo = await queue.next(lane: "duo", shouldStop: Self.deadline())
        XCTAssertEqual(forDuo?.info.id, "S1")
        await queue.laneEnded("duo")
        let pro = await forPro
        XCTAssertNil(pro, "試した pro へは戻さない")
    }

    func testAllLanesTriedFinalizesSkipped() async {
        let s1 = item("S1")
        let queue = ScenarioQueue([])
        await queue.laneJoined("a")
        await queue.laneJoined("b")
        let first = await queue.noteNotApplicable(s1, lane: "a", reason: "r")
        XCTAssertEqual(first, .handOn)
        let second = await queue.noteNotApplicable(s1, lane: "b", reason: "r")
        XCTAssertEqual(second, .skipped)
    }

    func testOnlyLaneFinalizesSkipped() async {
        let queue = ScenarioQueue([])
        await queue.laneJoined("a")
        let verdict = await queue.noteNotApplicable(item("S1"), lane: "a", reason: "r")
        XCTAssertEqual(verdict, .skipped, "最初から他の台が居なければ従来どおり対象外")
    }

    func testLaneThatNeverJoinedFinalizesNotRun() async {
        let queue = ScenarioQueue([])
        await queue.laneJoined("pro")
        await queue.laneNeverJoined("duo")
        let verdict = await queue.noteNotApplicable(item("S1"), lane: "pro", reason: "r")
        XCTAssertEqual(verdict, .notRun, "供給で合流しなかった台は試していない台が落ちたもの")
    }

    func testLaneStillSupplyingIsNotCountedAsDeparted() async {
        // 供給中の台は記帳しない(遅れて合流できる)。記帳前の判定は従来どおり対象外
        let queue = ScenarioQueue([])
        await queue.laneJoined("pro")
        let verdict = await queue.noteNotApplicable(item("S1"), lane: "pro", reason: "r")
        XCTAssertEqual(verdict, .skipped)
    }

    func testNeverJoinedLaneThatLaterJoinsIsLive() async {
        let queue = ScenarioQueue([])
        await queue.laneJoined("pro")
        await queue.laneNeverJoined("duo")
        await queue.laneJoined("duo")
        let verdict = await queue.noteNotApplicable(item("S1"), lane: "pro", reason: "r")
        XCTAssertEqual(verdict, .handOn)
    }

    func testRegisterNeverJoinedOnlyMissingLanesOfThePlatform() async {
        let ios = ScenarioQueue([])
        let android = ScenarioQueue([])
        await ios.laneJoined("pro")
        await RunOrchestrator.registerNeverJoined(
            planned: [(lane: "pro", platform: "ios"), (lane: "duo", platform: "ios"), (lane: "pix", platform: "android")],
            joinedLanes: ["pro"], queues: ["ios": ios, "android": android], isShared: true)
        let i = await ios.noteNotApplicable(item("S1"), lane: "pro", reason: "r")
        XCTAssertEqual(i, .notRun)
        await android.laneJoined("x")
        let a = await android.noteNotApplicable(item("S2"), lane: "x", reason: "r")
        XCTAssertEqual(a, .notRun, "android の pix も合流していない")
    }

    func testNeverJoinedIgnoresAnAlreadyLiveLane() async {
        let queue = ScenarioQueue([])
        await queue.laneJoined("pro")
        await queue.laneJoined("duo")
        await queue.laneNeverJoined("duo")
        let verdict = await queue.noteNotApplicable(item("S1"), lane: "pro", reason: "r")
        XCTAssertEqual(verdict, .handOn, "合流済みの台は落ちた台にしない")
        let departed = await queue.hasDepartedUntried(item("S1"))
        XCTAssertFalse(departed, "合流済みの台を落ちた台として数えない")
    }

    func testRegisterNeverJoinedDoesNotCountLanesAboutToJoin() async {
        // 記帳は合流(laneJoined)より前に行う。これから合流する台(joinedLanes)を落ちた台にすると、開始ゲートを待つ間に失敗と読まれる
        let queue = ScenarioQueue([])
        await queue.laneJoined("other")
        await RunOrchestrator.registerNeverJoined(
            planned: [(lane: "pro", platform: "ios")], joinedLanes: ["pro"], queues: ["ios": queue], isShared: true)
        let departed = await queue.hasDepartedUntried(item("S1"))
        XCTAssertFalse(departed)
    }

    func testRegisterNeverJoinedSkipsBroadcast() async {
        let q = ScenarioQueue([])
        await q.laneJoined("pro")
        await RunOrchestrator.registerNeverJoined(planned: [(lane: "duo", platform: "ios")], joinedLanes: [],
                                                  queues: ["ios": q], isShared: false)
        let v = await q.noteNotApplicable(item("S1"), lane: "pro", reason: "r")
        XCTAssertEqual(v, .skipped)
    }

    func testUntriedLaneThatLeftFinalizesNotRun() async {
        let queue = ScenarioQueue([])
        await queue.laneJoined("duo")
        await queue.laneJoined("pro")
        await queue.laneEnded("duo")
        let verdict = await queue.noteNotApplicable(item("S1"), lane: "pro", reason: "r")
        XCTAssertEqual(verdict, .notRun)
        let departed = await queue.hasDepartedUntried(item("S1"))
        XCTAssertTrue(departed)
    }

    /// デバイスに束ねたクラスは別の台へ動かさない(従来どおり対象外で確定)
    func testBoundClassIsNeverHandedOn() async {
        let queue = ScenarioQueue([])
        await queue.laneJoined("a")
        await queue.laneJoined("b")
        let verdict = await queue.noteNotApplicable(item("C.S1", placement: .singleDevice), lane: "a", reason: "r")
        XCTAssertEqual(verdict, .skipped)
    }

    /// 尽きたレーンは、ほかのレーンが走らせている item が対象外で戻ってくるかもしれない間は終わらない
    func testIdleLaneWaitsForAnotherLanesRunningItem() async {
        let s1 = item("S1")
        let queue = ScenarioQueue([s1])
        await queue.laneJoined("duo")
        await queue.laneJoined("pro")
        let taken = await queue.next(lane: "pro", shouldStop: Self.deadline())
        XCTAssertEqual(taken?.info.id, "S1")
        async let forDuo = queue.next(lane: "duo", shouldStop: Self.deadline())
        try? await Task.sleep(for: .milliseconds(100))
        _ = await queue.noteNotApplicable(s1, lane: "pro", reason: "fold")
        let got = await forDuo
        XCTAssertEqual(got?.info.id, "S1", "duo は尽きて終わらず、戻ってきた S1 を取る")
    }

    /// 試して対象外だった台だけが残った item は、試した台へ戻さずドレインに残り、理由を引ける(実行しなかった赤にする材料)
    func testStrandedItemKeepsItsDeclaredReason() async {
        let s1 = item("S1")
        let queue = ScenarioQueue([])
        await queue.laneJoined("a")
        await queue.laneJoined("b")
        _ = await queue.noteNotApplicable(s1, lane: "a", reason: "fold")
        await queue.laneEnded("b")
        let got = await queue.next(lane: "a", shouldStop: Self.deadline())
        XCTAssertNil(got, "試した a へは戻さない")
        let local = await queue.nextLocal()
        XCTAssertEqual(local?.info.id, "S1")
        let reason = await queue.declaredReason(for: s1)
        XCTAssertEqual(reason, "fold")
    }
}
