// 台の条件の機械内の入口(DR-237)。宣言なしは性質を見ない・読めなかった台は合わない台に丸めない・afterAll の宛先は条件に合う台。
import XCTest
@testable import FTCore

final class DeviceRequirementGateTests: XCTestCase {
    private let fold = DeviceRequirementSet(required: [.foldable])
    private func traits(foldable: Bool?) -> DeviceTraits {
        DeviceTraits(platform: "ios", physical: false, foldable: foldable, homeButton: false, osVersion: "iOS 27.2", model: "iPhone")
    }

    func testNoRequirementsNeverLooksAtTraits() {
        XCTAssertEqual(DeviceRequirementGate.fit(nil, traits: nil), .fits)
        XCTAssertEqual(DeviceRequirementGate.fit(DeviceRequirementSet(), traits: nil), .fits)
        XCTAssertTrue(DeviceRequirementGate.permits(nil, traits: nil))
    }

    func testRequirementWithoutObservationIsUnreadable() {
        XCTAssertEqual(DeviceRequirementGate.fit(fold, traits: nil), .unreadable(traits: ["traits"]))
        XCTAssertFalse(DeviceRequirementGate.permits(fold, traits: nil))
        XCTAssertFalse(DeviceRequirementGate.permits(fold, traits: traits(foldable: nil)))
        XCTAssertFalse(DeviceRequirementGate.permits(fold, traits: traits(foldable: false)))
        XCTAssertTrue(DeviceRequirementGate.permits(fold, traits: traits(foldable: true)))
    }

    func testAnyFittingLaneMeansNoConclusion() {
        let lanes = [(id: "a", traits: traits(foldable: nil)), (id: "b", traits: traits(foldable: true))]
        XCTAssertNil(DeviceRequirementGate.conclusion(fold, lanes: lanes))
        XCTAssertNil(DeviceRequirementGate.conclusion(fold, lanes: []), "台が1つも参加していない = 結論にしない(通常のドレイン)")
    }

    /// 読めなかった台が1台でもあれば失敗(全台が読めて合わないときだけ対象外)。事実(台と性質)を載せる
    func testUnreadableLaneMakesItAFailureAndReadableMissIsASkip() {
        let mixed = [(id: "a", traits: traits(foldable: false)), (id: "b", traits: traits(foldable: nil))]
        guard case .failed(let reason)? = DeviceRequirementGate.conclusion(fold, lanes: mixed) else { return XCTFail("failed expected") }
        XCTAssertTrue(reason.contains("b: unreadable (foldable)"), reason)
        XCTAssertTrue(reason.contains("a: unfit"), reason)
        XCTAssertTrue(reason.contains(".foldable"), reason)

        let readable = [(id: "a", traits: traits(foldable: false)), (id: "c", traits: traits(foldable: false))]
        guard case .skipped(let skip)? = DeviceRequirementGate.conclusion(fold, lanes: readable) else { return XCTFail("skipped expected") }
        XCTAssertTrue(skip.contains("no matching device"), skip)
        XCTAssertTrue(skip.contains("a: unfit"), skip)
        guard case .skipped(let per)? = DeviceRequirementGate.conclusion(fold, lanes: readable, perDevice: true) else {
            return XCTFail("skipped expected")
        }
        XCTAssertTrue(per.contains("conditions not met"), per)
    }

    func testAbsentFittingOrUnreadableDeviceBlocksTheGreenSkip() {
        let joined = [(id: "a", traits: traits(foldable: false))]
        guard case .failed(let r1)? = DeviceRequirementGate.conclusion(fold, lanes: joined, absent: [(id: "x", traits: traits(foldable: true))])
        else { return XCTFail("failed expected") }
        XCTAssertTrue(r1.contains("x: fits but did not take part"), r1)
        guard case .failed = DeviceRequirementGate.conclusion(fold, lanes: joined, absent: [(id: "y", traits: nil)])
        else { return XCTFail("failed expected") }
        guard case .skipped = DeviceRequirementGate.conclusion(fold, lanes: joined, absent: [(id: "z", traits: traits(foldable: false))])
        else { return XCTFail("skipped expected") }
        XCTAssertNil(DeviceRequirementGate.conclusion(fold, lanes: [], absent: [(id: "x", traits: traits(foldable: true))]))
    }

    func testClassLevelIsTheIntersectionAndAnyUndeclaredTestEmptiesIt() {
        let a = DeviceRequirementSet(required: [.foldable, .physical], excluded: [.homeButton])
        let b = DeviceRequirementSet(required: [.foldable], excluded: [.homeButton, .virtual])
        XCTAssertEqual(DeviceRequirementGate.classLevel(of: [a, b]), DeviceRequirementSet(required: [.foldable], excluded: [.homeButton]))
        XCTAssertTrue(DeviceRequirementGate.classLevel(of: [a, nil]).isEmpty)
        XCTAssertTrue(DeviceRequirementGate.classLevel(of: [nil, a]).isEmpty)
        XCTAssertTrue(DeviceRequirementGate.classLevel(of: []).isEmpty)
    }

    func testAfterAllPicksTheFirstFittingLaneOfThePlatform() {
        let lanes: [(id: String, platform: String, traits: DeviceTraits)] = [
            (id: "a", platform: "ios", traits: traits(foldable: false)),
            (id: "b", platform: "ios", traits: traits(foldable: true)),
            (id: "c", platform: "android", traits: DeviceTraits(platform: "android", physical: false, foldable: true)),
        ]
        XCTAssertEqual(DeviceRequirementGate.chooseAfterAllLane(requirements: fold, platforms: ["ios"], lanes: lanes), .lane(1))
        XCTAssertEqual(DeviceRequirementGate.chooseAfterAllLane(requirements: DeviceRequirementSet(), platforms: ["ios"], lanes: lanes),
                       .lane(0), "条件の無いクラスは従来どおり最初の台")
        XCTAssertEqual(DeviceRequirementGate.chooseAfterAllLane(requirements: DeviceRequirementSet(), platforms: [], lanes: lanes),
                       .lane(0))
    }

    func testAfterAllWithoutAFittingLaneSaysWhy() {
        let lanes: [(id: String, platform: String, traits: DeviceTraits)] = [
            (id: "a", platform: "ios", traits: traits(foldable: false)),
            (id: "b", platform: "ios", traits: traits(foldable: nil)),
        ]
        guard case .none(let reason?) = DeviceRequirementGate.chooseAfterAllLane(requirements: fold, platforms: ["ios"], lanes: lanes)
        else { return XCTFail("none with a reason expected") }
        XCTAssertTrue(reason.contains("b: unreadable (foldable)"), reason)
        XCTAssertEqual(DeviceRequirementGate.chooseAfterAllLane(requirements: fold, platforms: ["android"], lanes: lanes),
                       .none(reason: nil), "その OS の台が1つも無いときは既定の文言")
    }

    func testIneligibleLanesAreTheOnesTheConditionsRejectOrCannotRead() {
        let map = ["a": traits(foldable: false), "b": traits(foldable: true)]
        XCTAssertEqual(DeviceRequirementGate.ineligible(fold, among: ["a", "b", "c"], traits: map), ["a", "c"])
        XCTAssertTrue(DeviceRequirementGate.ineligible(nil, among: ["a", "c"], traits: map).isEmpty)
    }
}
