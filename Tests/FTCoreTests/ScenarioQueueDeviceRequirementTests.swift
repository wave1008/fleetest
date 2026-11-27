// 台の条件(DR-237)のキュー側: 合わない・読めなかったレーンへは配らない・対象外の回し直しは条件に合うレーンだけ・
// 条件の無い item は従来と同一。
import XCTest
@testable import FTCore

final class ScenarioQueueDeviceRequirementTests: XCTestCase {
    private let fold = DeviceRequirementSet(required: [.foldable])
    private func traits(foldable: Bool?) -> DeviceTraits {
        DeviceTraits(platform: "ios", physical: false, foldable: foldable, homeButton: false, osVersion: "iOS 27.2", model: "iPhone")
    }
    private func item(_ id: String, requires: DeviceRequirementSet? = nil, placement: ClassPlacement? = nil) -> ScenarioRunItem {
        ScenarioRunItem(info: ScenarioInfo(id: id, title: id, platform: "ios", placement: placement, deviceRequirements: requires),
                        variant: nil)
    }
    private static func deadline(_ seconds: Double = 5) -> @Sendable () async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        return { Date() > end }
    }

    /// 条件の無い item は性質を見ない: 性質の無いレーンも先頭から順に取る(従来と同一)
    func testRequirementLessItemsAreUnaffectedEvenForLanesWithoutTraits() async {
        let queue = ScenarioQueue([item("S1"), item("S2"), item("S3", requires: DeviceRequirementSet())])
        await queue.laneJoined("a")
        await queue.laneJoined("b", traits: traits(foldable: false))
        let first = await queue.next(lane: "a", shouldStop: Self.deadline())
        let second = await queue.next(lane: "b", shouldStop: Self.deadline())
        let third = await queue.next(lane: "a", shouldStop: Self.deadline())
        XCTAssertEqual([first?.info.id, second?.info.id, third?.info.id], ["S1", "S2", "S3"])
    }

    func testFittingLaneTakesItAndUnfitOrUnreadableLanesNever() async {
        let s1 = item("S1", requires: fold)
        let queue = ScenarioQueue([s1])
        await queue.laneJoined("plain", traits: traits(foldable: false))
        await queue.laneJoined("blind", traits: traits(foldable: nil))
        await queue.laneJoined("unobserved")
        await queue.laneJoined("duo", traits: traits(foldable: true))
        async let plain = queue.next(lane: "plain", shouldStop: Self.deadline(1))
        async let blind = queue.next(lane: "blind", shouldStop: Self.deadline(1))
        async let unobserved = queue.next(lane: "unobserved", shouldStop: Self.deadline(1))
        try? await Task.sleep(for: .milliseconds(100))
        let duo = await queue.next(lane: "duo", shouldStop: Self.deadline())
        XCTAssertEqual(duo?.info.id, "S1")
        await queue.laneEnded("duo")
        let others = await [plain, blind, unobserved]
        XCTAssertEqual(others.compactMap { $0 }.count, 0, "合わない・読めなかったレーンが取った")
    }

    /// 合う台が無い item は手元に残る(ドレインが結論を出す)。残りを待ち続けない
    func testItemNoLaneFitsStaysInTheQueueAndTheLanesFinish() async {
        let queue = ScenarioQueue([item("S1", requires: fold), item("S2")])
        await queue.laneJoined("plain", traits: traits(foldable: false))
        let first = await queue.next(lane: "plain", shouldStop: Self.deadline())
        XCTAssertEqual(first?.info.id, "S2")
        let second = await queue.next(lane: "plain", shouldStop: Self.deadline())
        XCTAssertNil(second)
        await queue.laneEnded("plain")
        let left = await queue.nextLocal()
        XCTAssertEqual(left?.info.id, "S1")
        let joined = await queue.joinedLaneTraits()
        XCTAssertEqual(joined.map(\.id), ["plain"])
    }

    /// 宣言に合うレーンが実行時に対象外と宣言したら、条件に合う別のレーンへ回し直す(合わないレーンへは回さない)
    func testRuntimeNotApplicableOnADeclaredFittingLaneIsHandedToAnotherFittingLaneOnly() async {
        let s1 = item("S1", requires: fold)
        let queue = ScenarioQueue([s1])
        await queue.laneJoined("duoA", traits: traits(foldable: true))
        await queue.laneJoined("duoB", traits: traits(foldable: true))
        await queue.laneJoined("plain", traits: traits(foldable: false))
        let taken = await queue.next(lane: "duoA", shouldStop: Self.deadline())
        XCTAssertEqual(taken?.info.id, "S1")
        let verdict = await queue.noteNotApplicable(s1, lane: "duoA", reason: "fold")
        XCTAssertEqual(verdict, .handOn)
        async let forPlain = queue.next(lane: "plain", shouldStop: Self.deadline(1))
        try? await Task.sleep(for: .milliseconds(100))
        let forB = await queue.next(lane: "duoB", shouldStop: Self.deadline())
        XCTAssertEqual(forB?.info.id, "S1")
        await queue.laneEnded("duoB")
        await queue.laneEnded("duoA")
        let plain = await forPlain
        XCTAssertNil(plain)
    }

    /// 他のレーンが全部合わない(配られない = 試した扱い)なら、回し直さず対象外のまま確定する
    func testUnfitLanesCountAsTriedForTheHandoff() async {
        let s1 = item("S1", requires: fold)
        let queue = ScenarioQueue([])
        await queue.laneJoined("duo", traits: traits(foldable: true))
        await queue.laneJoined("plain", traits: traits(foldable: false))
        await queue.laneJoined("blind", traits: traits(foldable: nil))
        let verdict = await queue.noteNotApplicable(s1, lane: "duo", reason: "fold")
        XCTAssertEqual(verdict, .skipped)
        // 条件の無い item は従来どおり他のレーンへ回す
        let plainItem = item("S2")
        let handOn = await queue.noteNotApplicable(plainItem, lane: "duo", reason: "x")
        XCTAssertEqual(handOn, .handOn)
    }

    /// @RunInOrder のクラスは、最初の1本を取れる(条件に合う)レーンに束ねる
    func testInOrderClassBindsToAFittingLane() async {
        let members = [item("C.S0010", requires: fold, placement: .inOrder), item("C.S0020", requires: fold, placement: .inOrder)]
        let queue = ScenarioQueue(members)
        await queue.laneJoined("plain", traits: traits(foldable: false))
        await queue.laneJoined("duo", traits: traits(foldable: true))
        async let plain = queue.next(lane: "plain", shouldStop: Self.deadline(1))
        try? await Task.sleep(for: .milliseconds(100))
        let first = await queue.next(lane: "duo", shouldStop: Self.deadline())
        let second = await queue.next(lane: "duo", shouldStop: Self.deadline())
        XCTAssertEqual([first?.info.id, second?.info.id], ["C.S0010", "C.S0020"])
        await queue.laneEnded("duo", orphaning: false)
        let p = await plain
        XCTAssertNil(p)
    }
}
