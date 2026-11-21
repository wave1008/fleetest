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
