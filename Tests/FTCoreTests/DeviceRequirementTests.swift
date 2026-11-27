// 台の条件の判定(読めない台を配る・他OSの条件が台を縛る・同着で台が揺れる)が壊れると、シナリオが合わない台へ配られる/最低1台が残らない。
import XCTest
@testable import FTCore

final class DeviceRequirementTests: XCTestCase {
    private func ios(physical: Bool = false, foldable: Bool? = false, home: Bool? = false,
                     os: String? = "iOS 18.2", model: String? = "iPhone 16") -> DeviceTraits {
        DeviceTraits(platform: "ios", physical: physical, foldable: foldable, homeButton: home, osVersion: os, model: model)
    }
    private func android(os: String? = "Android 15", model: String? = "Pixel 9") -> DeviceTraits {
        DeviceTraits(platform: "android", physical: false, foldable: false, homeButton: false, osVersion: os, model: model)
    }
    private func req(_ c: DeviceCondition...) -> DeviceRequirementSet { DeviceRequirementSet(required: c) }
    private func exc(_ c: DeviceCondition...) -> DeviceRequirementSet { DeviceRequirementSet(excluded: c) }

    func testMinOSReadsTheLeadingNumberOfAnAPI32Emulator() {
        // API 32 = "Android 12L"(androidVersionName の表で数字だけでない値はこれだけ)。12L は 12 以上・13 未満
        let l = android(os: "Android 12L")
        XCTAssertEqual(DeviceRequirementMatch.fit(req(.minOS(platform: "android", version: "12")), l), .fits)
        guard case .unfit = DeviceRequirementMatch.fit(req(.minOS(platform: "android", version: "13")), l)
        else { return XCTFail("12L is below 13") }
        XCTAssertEqual(DeviceRequirementMatch.fit(req(.os("Android 12*")), l), .fits)
        for api in 21...40 {
            let name = RunProfileDeviceEditor.androidVersionName(apiLevel: api)
            XCTAssertNotNil(DeviceVersion.parseLeading(String(name.dropFirst("Android ".count))), "\(name) must be readable for minOS")
        }
        XCTAssertNil(DeviceVersion.parseLeading("L12"))
        XCTAssertNil(DeviceVersion.parseLeading("12."))
        XCTAssertNil(DeviceVersion.parseLeading("12.4x5"))
    }

    func testOtherOSConditionsDoNotBindThisDevice() {
        XCTAssertEqual(DeviceRequirementMatch.fit(req(.minOS(platform: "android", version: "99")), ios()), .fits)
        XCTAssertEqual(DeviceRequirementMatch.fit(req(.os("Android 1*")), ios()), .fits)
        XCTAssertEqual(DeviceRequirementMatch.fit(exc(.os("Android*")), ios()), .fits)
        XCTAssertEqual(DeviceRequirementMatch.fit(exc(.minOS(platform: "ios", version: "1")), android()), .fits)
        // 他OSの条件は osVersion が nil でも読めない扱いにしない
        XCTAssertEqual(DeviceRequirementMatch.fit(req(.os("Android*")), ios(os: nil)), .fits)
    }

    func testUnreadableBeatsFitsAndUnfit() {
        XCTAssertEqual(DeviceRequirementMatch.fit(req(.foldable), ios(foldable: nil)), .unreadable(traits: ["foldable"]))
        // 除外の条件でも nil なら unreadable
        XCTAssertEqual(DeviceRequirementMatch.fit(exc(.foldable), ios(foldable: nil)), .unreadable(traits: ["foldable"]))
        // 別の必須が確定で外れていても、縛る性質が nil なら unreadable が勝つ
        XCTAssertEqual(DeviceRequirementMatch.fit(req(.physical, .model("X*")), ios(model: nil)),
                       .unreadable(traits: ["model"]))
        XCTAssertEqual(DeviceRequirementMatch.fit(req(.model("iPhone*")), ios(model: nil)), .unreadable(traits: ["model"]))
        XCTAssertEqual(DeviceRequirementMatch.fit(req(.os("iOS 18*")), ios(os: nil)), .unreadable(traits: ["osVersion"]))
    }

    func testExclusionBeatsRequirement() {
        let set = DeviceRequirementSet(required: [.virtual], excluded: [.model("iPhone*")])
        guard case .unfit(let reasons) = DeviceRequirementMatch.fit(set, ios()) else { return XCTFail("unfit expected") }
        XCTAssertEqual(reasons.count, 1)
        XCTAssertEqual(DeviceRequirementMatch.fit(set, android()), .fits)
    }

    func testPhysicalAndVirtualUseProfileKind() {
        XCTAssertEqual(DeviceRequirementMatch.fit(req(.physical), ios(physical: true)), .fits)
        XCTAssertEqual(DeviceRequirementMatch.fit(req(.physical), ios()), .unfit(reasons: [".physical is required"]))
        XCTAssertEqual(DeviceRequirementMatch.fit(req(.virtual), ios()), .fits)
        XCTAssertEqual(DeviceRequirementMatch.fit(exc(.virtual), ios()), .unfit(reasons: [".virtual is excluded"]))
    }

    func testHomeButtonFalseIsDecidedNilIsUnreadable() {
        XCTAssertEqual(DeviceRequirementMatch.fit(req(.homeButton), android()), .unfit(reasons: [".homeButton is required"]))
        XCTAssertEqual(DeviceRequirementMatch.fit(exc(.homeButton), android()), .fits)
        XCTAssertEqual(DeviceRequirementMatch.fit(req(.homeButton), ios(home: true)), .fits)
        XCTAssertEqual(DeviceRequirementMatch.fit(req(.homeButton), ios(home: nil)), .unreadable(traits: ["homeButton"]))
    }

    func testMinOSComparesNumerically() {
        let at = { (v: String, os: String) in DeviceRequirementMatch.fit(self.req(.minOS(platform: "ios", version: v)), self.ios(os: os)) }
        XCTAssertEqual(at("17.4", "iOS 17.10"), .fits)
        XCTAssertEqual(at("17.10", "iOS 17.4"), .unfit(reasons: [".minOS(ios: \"17.10\") is required"]))
        XCTAssertEqual(at("18", "iOS 18.0.1"), .fits)
        XCTAssertEqual(at("18.0.1", "iOS 18"), .unfit(reasons: [".minOS(ios: \"18.0.1\") is required"]))
        XCTAssertEqual(at("18.0", "iOS 18"), .fits)
        XCTAssertEqual(at("18", "iOS"), .unreadable(traits: ["osVersion"]))
        XCTAssertEqual(at("18", "garbage"), .unreadable(traits: ["osVersion"]))
        XCTAssertEqual(DeviceRequirementMatch.fit(req(.minOS(platform: "android", version: "16")), android(os: "Android 17")), .fits)
    }

    func testOSPatternWithStarAndAlternatives() {
        XCTAssertEqual(DeviceRequirementMatch.fit(req(.os("iOS 18*")), ios()), .fits)
        XCTAssertEqual(DeviceRequirementMatch.fit(req(.os("iOS 17*")), ios()),
                       .unfit(reasons: [".os(\"iOS 17*\") is required"]))
        XCTAssertEqual(DeviceRequirementMatch.fit(req(.os("iOS 17*||Android 15")), android()), .fits)
        XCTAssertEqual(DeviceRequirementMatch.fit(req(.os("iOS 17*||Android 15")), ios()),
                       .unfit(reasons: [".os(\"iOS 17*||Android 15\") is required"]))
        XCTAssertEqual(DeviceRequirementMatch.fit(req(.model("iPhone 1*||Pixel*")), ios()), .fits)
    }

    func testDeclarationError() {
        XCTAssertNil(DeviceCondition.declarationError(.os("iOS 18*||Android 1*")))
        XCTAssertNotNil(DeviceCondition.declarationError(.os("17*")))
        XCTAssertNotNil(DeviceCondition.declarationError(.os("iOS 18*||17*")))
        XCTAssertNotNil(DeviceCondition.declarationError(.os("")))
        XCTAssertNotNil(DeviceCondition.declarationError(.model("a||")))
        XCTAssertNil(DeviceCondition.declarationError(.model("iPhone*")))
        XCTAssertNil(DeviceCondition.declarationError(.minOS(platform: "ios", version: "17.4")))
        XCTAssertNotNil(DeviceCondition.declarationError(.minOS(platform: "windows", version: "1")))
        for v in ["", "17.", ".4", "17.x", "-1", "17..4", "v17"] {
            XCTAssertNotNil(DeviceCondition.declarationError(.minOS(platform: "ios", version: v)), v)
        }
        XCTAssertNil(DeviceCondition.declarationError(.foldable))
    }

    func testContradictionsAndMerging() {
        XCTAssertEqual(DeviceRequirementSet(required: [.physical, .virtual]).contradictions.count, 1)
        XCTAssertEqual(DeviceRequirementSet(required: [.foldable], excluded: [.foldable]).contradictions.count, 1)
        XCTAssertTrue(DeviceRequirementSet(required: [.physical], excluded: [.foldable]).contradictions.isEmpty)
        let m = DeviceRequirementSet.merging(class: DeviceRequirementSet(required: [.physical, .foldable], excluded: [.homeButton]),
                                             test: DeviceRequirementSet(required: [.foldable, .model("a")], excluded: [.homeButton]))
        XCTAssertEqual(m.required, [.physical, .foldable, .model("a")])
        XCTAssertEqual(m.excluded, [.homeButton])
        XCTAssertTrue(DeviceRequirementSet().isEmpty)
        XCTAssertFalse(m.isEmpty)
    }

    func testPartitionPreservesOrderAndNoMatchFacts() {
        let devs: [DeviceRequirementMatch.Device] = [
            ("d", ios(physical: true)), ("a", ios()), ("c", ios(physical: true, foldable: nil)), ("b", android()),
        ]
        let set = DeviceRequirementSet(required: [.physical], excluded: [.foldable])
        let p = DeviceRequirementMatch.partition(set, devices: devs)
        XCTAssertEqual(p.fits, ["d"])
        XCTAssertEqual(p.unfit, ["a", "b"])
        XCTAssertEqual(p.unreadable, ["c"])
        let facts = DeviceRequirementMatch.noMatchFacts(set, devices: devs)
        XCTAssertEqual(facts.count, 3)
        XCTAssertTrue(facts.contains { $0.hasPrefix("c: unreadable") && $0.contains("foldable") })
        XCTAssertTrue(facts.contains { $0.hasPrefix("a: unfit") })
    }

    func testMustKeepOnePerSetWithTotalOrder() {
        let ids = ["m3", "m1", "m2", "z9"]
        let devs: [DeviceRequirementMatch.Device] = ids.map { ($0, ios(physical: $0 != "z9")) }
        let phys = req(.physical), virt = req(.virtual), none = req(.foldable)
        let sets = [phys, virt, none, DeviceRequirementSet(), phys]
        let expected: Set<String> = ["m1", "z9"]
        for order in [devs, devs.reversed(), [devs[2], devs[0], devs[3], devs[1]]] {
            XCTAssertEqual(DeviceRequirementMatch.mustKeep(sets: sets, devices: order), expected)
        }
    }
}

final class ValuePatternTests: XCTestCase {
    func testStarSemanticsAndAlternatives() {
        XCTAssertTrue(ValuePattern.patternMatches("abc", value: "abc"))
        XCTAssertFalse(ValuePattern.patternMatches("ab", value: "abc"))
        XCTAssertTrue(ValuePattern.patternMatches("ab*", value: "abc"))
        XCTAssertTrue(ValuePattern.patternMatches("*bc", value: "abc"))
        XCTAssertTrue(ValuePattern.patternMatches("*b*", value: "abc"))
        XCTAssertFalse(ValuePattern.patternMatches("a*c", value: "abc"), "中間の * はリテラル")
        XCTAssertTrue(ValuePattern.patternMatches("x||abc", value: "abc"))
        XCTAssertFalse(ValuePattern.patternMatches("abc||", value: nil))
        XCTAssertEqual(ValuePattern.alternatives(" a || b ||"), ["a", "b"])
        XCTAssertNotNil(ValuePattern.patternError("a||", argument: "x"))
    }

    func testDescribedUsesDSLSpelling() {
        XCTAssertEqual(DeviceCondition.foldable.described, ".foldable")
        XCTAssertEqual(DeviceCondition.homeButton.described, ".homeButton")
        XCTAssertEqual(DeviceCondition.minOS(platform: "android", version: "15").described, ".minOS(android: \"15\")")
        XCTAssertEqual(DeviceCondition.model("iPhone*").described, ".model(\"iPhone*\")")
        XCTAssertEqual(DeviceCondition.os("iOS 27*").described, ".os(\"iOS 27*\")")
        XCTAssertEqual(DeviceRequirementSet(required: [.foldable], excluded: [.foldable]).contradictions,
                       [".foldable is both required and excluded"])
    }

    func testScenarioInfoのdeviceRequirementsはJSONを往復する() throws {
        let set = DeviceRequirementSet(required: [.foldable, .minOS(platform: "ios", version: "18"), .model("a*||b")],
                                       excluded: [.os("iOS 17*")])
        let info = ScenarioInfo(id: "T.S0010", title: "t", deviceRequirements: set)
        let back = try JSONDecoder().decode(ScenarioInfo.self, from: JSONEncoder().encode(info))
        XCTAssertEqual(back, info)
        XCTAssertEqual(back.deviceRequirements, set)
        let none = try JSONDecoder().decode(ScenarioInfo.self, from: JSONEncoder().encode(ScenarioInfo(id: "T.S0020", title: "")))
        XCTAssertNil(none.deviceRequirements)
    }
}
