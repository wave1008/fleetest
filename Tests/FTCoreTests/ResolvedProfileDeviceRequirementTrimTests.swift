// 台の条件(DR-237)つきの絞り込み(`ResolvedProfile.limitingDevices`)。
// 実害(デバイスで確認済み): [iPhone 18 Pro, iPhone Duo] のプロファイルで fold のシナリオ1本を名指しすると、`prefix(1)` で iPhone だけが残り
// Duo が供給されず対象外(緑)で終わった。ここは両方向を固定する —— 条件に合う台は並びに依らず残る / 宣言が無ければ従来どおり。

import XCTest
@testable import FTCore

final class ResolvedProfileDeviceRequirementTrimTests: XCTestCase {
    private func device(_ name: String, _ platform: String = "ios") -> ResolvedDevice {
        ResolvedDevice(platform: platform, spec: DeviceSpec(name: name, kind: .physical, udid: "U-\(name)"))
    }

    private func profile(_ devices: [ResolvedDevice]) -> ResolvedProfile {
        ResolvedProfile(
            project: TestProject(name: "dummy", rootURL: URL(fileURLWithPath: "/tmp/dummy")),
            runName: "r", appName: "app", apps: [:],
            devices: devices, fm: FMConfig(), heal: false,
            reportDir: URL(fileURLWithPath: "/tmp/dummy/reports"),
            defaultTimeout: nil, scenarioTimeout: nil, wipeDataOnBloat: true, updateWebView: false,
            wipeDataThresholdGB: 8, recoverCpuFallbackToGpu: false, locale: "ja_JP",
            iosPreActionPing: true, containerInference: true, ocrTextVisibilityCheck: true,
            preferCheckStateClassifier: true,
            enableAnimations: false, responseMeasurement: false, responseRepeat: 5,
            homeOnStart: true, playProtectBypass: true, record: false, recordFailuresOnly: false,
            recordBitrateKbps: 1500, recordFullResolution: false, warnings: [])
    }

    private let fold = DeviceRequirementSet(required: [.foldable])
    private let traits: [String: DeviceTraits] = [
        "Pro": DeviceTraits(platform: "ios", physical: false, foldable: false),
        "Duo": DeviceTraits(platform: "ios", physical: false, foldable: true),
        "Duo2": DeviceTraits(platform: "ios", physical: false, foldable: true),
    ]

    /// platform nil = どちらの OS の台にも掛ける(従来の形)
    private func req(_ set: DeviceRequirementSet, _ platform: String? = nil) -> ScenarioDeviceRequirement {
        ScenarioDeviceRequirement(set: set, platform: platform)
    }

    private func names(_ p: ResolvedProfile) -> [String] { p.devices.map(\.name) }

    /// **本命**: 1本の fold シナリオで、Duo は並びが先でも後でも残る
    func testFoldScenarioKeepsTheFoldableDeviceInEitherOrder() {
        for order in [["Pro", "Duo"], ["Duo", "Pro"]] {
            let kept = profile(order.map { device($0) }).limitingDevices(
                iosScenarios: 1, androidScenarios: 0, requirements: [req(fold)], traits: traits, avoiding: { _ in false })
            XCTAssertEqual(names(kept), ["Duo"], "order \(order)")
        }
    }

    /// 宣言が無ければ従来どおり先頭の1台(`prefix`)。**宣言の無い run の挙動は変えない**
    func testUndeclaredRunKeepsTheOldPrefix() {
        let kept = profile([device("Pro"), device("Duo")]).limitingDevices(
            iosScenarios: 1, androidScenarios: 0, requirements: [], traits: traits, avoiding: { _ in false })
        XCTAssertEqual(names(kept), ["Pro"])
        // 空の組(宣言はあるが条件が空)も同じ
        let empty = profile([device("Pro"), device("Duo")]).limitingDevices(
            iosScenarios: 1, androidScenarios: 0, requirements: [req(DeviceRequirementSet())], traits: traits, avoiding: { _ in false })
        XCTAssertEqual(names(empty), ["Pro"])
    }

    /// 必須の台の後に、本数の残りを従来の順で埋める(2本・先頭が合わない)
    func testFillsTheRestInTheOldOrderAfterTheRequiredDevice() {
        let kept = profile([device("Pro"), device("Duo"), device("Other")]).limitingDevices(
            iosScenarios: 2, androidScenarios: 0, requirements: [req(fold)], traits: traits, avoiding: { _ in false })
        XCTAssertEqual(names(kept), ["Pro", "Duo"])
    }

    /// 本数 0 の OS には必須の台も残さない(その OS で走るシナリオが無い)
    func testZeroCountOSKeepsNoRequiredDevice() {
        let kept = profile([device("Duo"), device("A1", "android")]).limitingDevices(
            iosScenarios: 0, androidScenarios: 1, requirements: [req(fold)], traits: traits, avoiding: { _ in false })
        XCTAssertEqual(names(kept), ["A1"])
    }

    /// 合う台が複数あれば1台だけ(識別子の辞書順で最小。入力順に依らない)
    func testOnlyOneMatchingDeviceIsForcedInAndTheChoiceDoesNotDependOnOrder() {
        for order in [["Duo2", "Duo", "Pro"], ["Pro", "Duo", "Duo2"]] {
            let kept = profile(order.map { device($0) }).limitingDevices(
                iosScenarios: 1, androidScenarios: 0, requirements: [req(fold)], traits: traits, avoiding: { _ in false })
            XCTAssertEqual(names(kept), ["Duo"], "order \(order)")
        }
    }

    /// MCP の操作中の台が必須なら残す(避けない。警告は呼び手)。ほかの台は従来どおり避ける
    func testRequiredDeviceHeldByMCPIsKeptAndTheRestStillAvoided() {
        let duo = device("Duo")
        let kept = profile([device("Pro"), duo]).limitingDevices(
            iosScenarios: 1, androidScenarios: 0, requirements: [req(fold)], traits: traits, avoiding: { $0 == duo })
        XCTAssertEqual(names(kept), ["Duo"])
        let two = profile([device("Pro"), duo, device("Other")]).limitingDevices(
            iosScenarios: 2, androidScenarios: 0, requirements: [req(fold)], traits: traits, avoiding: { $0 == duo })
        XCTAssertEqual(names(two), ["Pro", "Duo"])
    }

    /// 本数が分からない(nil)ときも必須の台は MCP の印があっても残る
    func testUnknownCountKeepsTheRequiredDeviceEvenIfAvoided() {
        let duo = device("Duo")
        let kept = profile([device("Pro"), duo]).limitingDevices(
            iosScenarios: nil, androidScenarios: nil, requirements: [req(fold)], traits: traits, avoiding: { $0 == duo })
        XCTAssertEqual(Set(names(kept)), ["Pro", "Duo"])
    }

    /// 合う台が無い組は、読めなかった台を1台残す(この run で使う台に読めない台があれば赤 = DR-237。落とすと残った台だけで
    /// 「合う台が無い」の緑に化ける = 陽性対照 11/27)。読めない台どうしの同着は識別子の辞書順
    func testUnreadableDeviceIsKeptWhenNoDeviceFits() {
        let kept = profile([device("Pro"), device("Duo")]).limitingDevices(
            iosScenarios: 1, androidScenarios: 0, requirements: [req(fold)], traits: [:], avoiding: { _ in false })
        XCTAssertEqual(names(kept), ["Duo"])
        let oneUnreadable = profile([device("Pro"), device("Duo")]).limitingDevices(
            iosScenarios: 1, androidScenarios: 0, requirements: [req(fold)],
            traits: ["Pro": DeviceTraits(platform: "ios", physical: false, foldable: false)], avoiding: { _ in false })
        XCTAssertEqual(names(oneUnreadable), ["Duo"])
        // 合う台があれば読めない台は残さない(合う台で走る)
        let fits = profile([device("Pro"), device("Duo"), device("X")]).limitingDevices(
            iosScenarios: 1, androidScenarios: 0, requirements: [req(fold)], traits: traits, avoiding: { _ in false })
        XCTAssertEqual(names(fits), ["Duo"])
    }

    /// 別の機械の台には手元の観測を当てない(同名でも読めなかった扱い = 合う台が無いので読めない台として残る)
    func testRemoteDeviceDoesNotTakeTheLocalObservationOfTheSameName() {
        let remote = ResolvedDevice(platform: "ios", spec: DeviceSpec(name: "Duo", machine: "M1", kind: .physical, udid: "U-R"))
        XCTAssertEqual(DeviceRequirementTrim.traits(of: remote, observed: traits).foldable, nil)
        let kept = profile([device("Pro"), remote]).limitingDevices(
            iosScenarios: 1, androidScenarios: 0, requirements: [req(fold)], traits: traits, avoiding: { _ in false })
        XCTAssertEqual(kept.devices.map(\.spec.machine), ["M1"])
    }

    /// 検算: 一覧の前に外した台が条件に要ったか
    func testShortfallNamesTheDeviceThatWasLeftOut() {
        let pro = device("Pro"), duo = device("Duo")
        let facts = DeviceRequirementTrim.shortfall(requirements: [fold], full: [pro, duo], kept: [pro], traits: traits)
        XCTAssertEqual(facts.count, 1)
        XCTAssertTrue(facts[0].contains("local/Duo"), "\(facts)")
        XCTAssertEqual(DeviceRequirementTrim.shortfall(requirements: [fold], full: [pro, duo], kept: [duo], traits: traits), [])
        // 合う台が全台に無ければ「外したせい」ではない(対象外の結論は別の段)
        XCTAssertEqual(DeviceRequirementTrim.shortfall(requirements: [fold], full: [pro], kept: [pro], traits: traits), [])
        XCTAssertEqual(DeviceRequirementTrim.shortfall(requirements: [], full: [pro, duo], kept: [pro], traits: traits), [])
        // 合う台が無く、読めなかった台を外していた = 赤の根拠を落としている
        let unread = DeviceRequirementTrim.shortfall(requirements: [fold], full: [pro, duo], kept: [pro],
                                                     traits: ["Pro": traits["Pro"]!])
        XCTAssertEqual(unread.count, 1)
        XCTAssertTrue(unread[0].contains("could not be checked on local/Duo"), "\(unread)")
    }

    /// 他の OS のシナリオの条件で、この OS の台を本数を超えて残さない: Android だけの fold のシナリオ1本・iOS 1本のとき、
    /// foldable を読めない iOS の台を「読めない台」として余分に残さない。Android 側は foldable の台を残す
    func testAnotherPlatformsRequirementDoesNotForceAnExtraDeviceOfThisPlatform() {
        let p = profile([device("Pro"), device("Duo"), device("A1", "android"), device("A2", "android")])
        let observed: [String: DeviceTraits] = [
            "A1": DeviceTraits(platform: "android", physical: false, foldable: false),
            "A2": DeviceTraits(platform: "android", physical: false, foldable: true),
        ]
        let kept = p.limitingDevices(
            iosScenarios: 1, androidScenarios: 1, requirements: [req(fold, "android")], traits: observed,
            avoiding: { _ in false })
        XCTAssertEqual(names(kept), ["Pro", "A2"])
        // platform 未指定(nil)は従来どおり両方に掛かる = iOS の読めない台も残る(対照)
        let both = p.limitingDevices(
            iosScenarios: 1, androidScenarios: 1, requirements: [req(fold)], traits: observed, avoiding: { _ in false })
        XCTAssertEqual(names(both), ["Duo", "A2"])
    }

    /// 一覧から条件を取り出すとき、platform 未宣言のシナリオは `undeclaredScenarioPlatform` の側(`scenarioCounts` と同じ規則)
    func testRequirementsOfScenariosResolveTheUndeclaredPlatform() {
        let p = profile([device("Pro"), device("A1", "android")])
        let infos = [
            ScenarioInfo(id: "C.S1", title: "a", platform: "android", deviceRequirements: fold),
            ScenarioInfo(id: "C.S2", title: "b", platform: nil, deviceRequirements: fold),
            ScenarioInfo(id: "C.S3", title: "c", platform: "ios", deviceRequirements: DeviceRequirementSet()),
        ]
        XCTAssertEqual(p.deviceRequirements(of: infos).map(\.platform), ["android", "ios"])
    }
}
