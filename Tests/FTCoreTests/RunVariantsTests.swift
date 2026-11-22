// 実行プロファイルの `variants`: 宣言の検査・解決・`--set` との併用禁止・展開(RunVariantPlan)・絞り込みの積集合(DR-223〜225)

import XCTest
@testable import FTCore

final class RunVariantsTests: XCTestCase {

    private func resolve(_ json: String, topAppearance: String? = nil, topTextSize: String? = nil,
                         topOrientation: String? = nil) throws -> [ResolvedVariant] {
        let entries = try JSONDecoder().decode([RunVariantEntry].self, from: Data(json.utf8))
        return try RunVariantResolution.resolve(
            entries: entries, topAppearance: topAppearance, topTextSize: topTextSize,
            topOrientation: topOrientation, run: "r")
    }

    func testUnwrittenKeysTakeTheTopLevelThenTheBase() throws {
        let resolved = try resolve(#"[{"name":"base"},{"name":"dark","appearance":"dark"},{"name":"big"}]"#,
                                   topTextSize: "large")
        XCTAssertEqual(resolved.map(\.name), ["base", "dark", "big"])
        // 最上位の textSize を全員が引き継ぎ、appearance は書いたものだけ dark・他は基準の light
        XCTAssertEqual(resolved.map(\.textSize), [.large, .large, .large])
        XCTAssertEqual(resolved.map(\.appearance), [.light, .dark, .light])
        // 解決した値は「指定あり」= nil にならない(基準の値も明示の値として運ぶ)
        XCTAssertEqual(try resolve(#"[{"name":"base"}]"#).first?.textSize, .default)
        XCTAssertNil(try resolve(#"[{"name":"base"}]"#).first?.orientation)
    }

    func testRejectsUnknownKeysDuplicatesEmptyAndInvalidValues() {
        XCTAssertThrowsError(try JSONDecoder().decode([RunVariantEntry].self, from: Data(#"[{"name":"a","apperance":"dark"}]"#.utf8)))
        XCTAssertThrowsError(try resolve("[]"))
        XCTAssertThrowsError(try resolve(#"[{"name":"a"},{"name":"a"}]"#))
        for bad in ["Dark", "1a", "a_b", "", "a b"] {
            XCTAssertThrowsError(try resolve(#"[{"name":"\#(bad)"}]"#), bad)
        }
        XCTAssertThrowsError(try resolve(#"[{"name":"a","appearance":"sepia"}]"#))
        XCTAssertThrowsError(try resolve(#"[{"name":"a","textSize":"huge"}]"#))
        XCTAssertThrowsError(try resolve(#"[{"name":"a","orientation":"sideways"}]"#))
        XCTAssertNoThrow(try resolve(#"[{"name":"dark-landscape-2","appearance":"dark","orientation":"landscape"}]"#))
    }

    func testOrientationMustBeWrittenByEveryVariantOrAtTheTop() throws {
        XCTAssertThrowsError(try resolve(#"[{"name":"a","orientation":"landscape"},{"name":"b"}]"#)) {
            XCTAssertTrue($0.localizedDescription.contains("\"b\""), "\($0)")
        }
        let viaTop = try resolve(#"[{"name":"a","orientation":"landscape"},{"name":"b"}]"#, topOrientation: "portrait")
        XCTAssertEqual(viaTop.map(\.orientation), ["landscape", "portrait"])
        let both = try resolve(#"[{"name":"a","orientation":"landscape"},{"name":"b","orientation":"portrait"}]"#)
        XCTAssertEqual(both.map(\.orientation), ["landscape", "portrait"])
    }

    func testSetOverridesOfDisplayKeysAreRefusedWithVariants() throws {
        let loaded = try JSONDecoder().decode(RunProfileDocument.self, from: Data(#"{"variants":[{"name":"a"}]}"#.utf8))
        for key in ["appearance=dark", "textSize=large", "orientation=landscape"] {
            let overrides = try RunProfileSetOverride.parse([key])
            XCTAssertThrowsError(try ProfileResolver.resolveVariants(loaded: loaded, overrides: overrides, run: "r"), key)
        }
        // `--set variants=` は配列の欄なので入口(parse)で断られる
        XCTAssertThrowsError(try RunProfileSetOverride.parse(["variants=x"]))
        // variants の無いプロファイルは今までどおり受ける
        let plain = RunProfileDocument()
        XCTAssertEqual(try ProfileResolver.resolveVariants(
            loaded: plain, overrides: try RunProfileSetOverride.parse(["appearance=dark"]), run: "r"), [])
    }

    func testStaticValidationReportsVariantProblems() {
        let json = #"{"app":"a","devices":[{"platform":"ios","name":"d"}],"variants":[{"name":"x"},{"name":"x"}]}"#
        let errors = ProfileResolver.validate(kind: .run, data: Data(json.utf8), context: "x").errors
        XCTAssertTrue(errors.contains { $0.contains("duplicate variant name") }, "\(errors)")
    }

    // MARK: - RunVariantPlan

    private func infos(_ ids: [String]) -> [ScenarioInfo] { ids.map { ScenarioInfo(id: $0, title: "") } }
    private func declared(_ names: [String]) -> [ResolvedVariant] {
        names.map { ResolvedVariant(name: $0, appearance: .light, textSize: .default, orientation: nil) }
    }

    func testUnitsAreScenarioOrderTimesDeclarationOrder() throws {
        let plan = try RunVariantPlan.make(declared: declared(["b", "a"]), variantNames: [], selectors: [], profile: "p")
        let units = plan.units(of: infos(["X.s1", "X.s2"])).map(\.description)
        XCTAssertEqual(units, ["X.s1@b", "X.s1@a", "X.s2@b", "X.s2@a"])
        XCTAssertEqual(plan.rank(of: "b"), 0)
        XCTAssertEqual(plan.rank(of: "a"), 1)
    }

    func testNoVariantsKeepsTheUnitWithoutAVariant() {
        XCTAssertEqual(RunVariantPlan.none.units(of: infos(["X.s1"])).map(\.description), ["X.s1"])
        XCTAssertEqual(RunVariantPlan.none.items(of: infos(["X.s1"])).map(\.variant), [nil])
    }

    func testVariantFilterKeepsDeclarationOrderAndRefusesUnknownNames() throws {
        let plan = try RunVariantPlan.make(declared: declared(["a", "b", "c"]), variantNames: ["c", "a"], selectors: [], profile: "p")
        XCTAssertEqual(plan.units(of: infos(["X.s1"])).map(\.description), ["X.s1@a", "X.s1@c"])
        XCTAssertEqual(plan.declaredNames, ["a", "b", "c"], "記録の母集団は絞る前の宣言")
        XCTAssertThrowsError(try RunVariantPlan.make(declared: declared(["a"]), variantNames: ["zz"], selectors: [], profile: "p"))
        XCTAssertThrowsError(try RunVariantPlan.make(declared: [], variantNames: ["a"], selectors: [], profile: "p"))
        XCTAssertThrowsError(try RunVariantPlan.make(declared: [], variantNames: [], selectors: ["X.s1@a"], profile: nil))
    }

    func testNamedUnitsAndTheIntersectionWithVariantAndFailed() throws {
        let all = infos(["X.s1", "X.s2"])
        // ID@variant はその1単位だけ。ID だけの指定は全バリアント(和集合)
        var plan = try RunVariantPlan.make(declared: declared(["a", "b"]), variantNames: [], selectors: ["X.s1@b", "X.s2"], profile: "p")
        XCTAssertEqual(plan.units(of: all).map(\.description), ["X.s1@b", "X.s2@a", "X.s2@b"])
        // --variant と併用したら積集合
        plan = try RunVariantPlan.make(declared: declared(["a", "b"]), variantNames: ["a"], selectors: ["X.s1@b", "X.s2"], profile: "p")
        XCTAssertEqual(plan.units(of: all).map(\.description), ["X.s2@a"])
        // --failed(失敗した単位)とも積集合
        plan = try RunVariantPlan.make(declared: declared(["a", "b"]), variantNames: ["b"], selectors: [], profile: "p")
            .restrictingToFailed([ScenarioUnitKey(id: "X.s1", variant: "a"), ScenarioUnitKey(id: "X.s2", variant: "b")])
        XCTAssertEqual(plan.units(of: all).map(\.description), ["X.s2@b"])
        XCTAssertEqual(plan.infos(all).map(\.id), ["X.s2"])
        // 知らないバリアントの名指しは断る
        XCTAssertThrowsError(try RunVariantPlan.make(declared: declared(["a"]), variantNames: [], selectors: ["X.s1@zz"], profile: "p"))
    }

    func testIdsStrippingVariantsKeepsFirstSeenOrderWithoutDuplicates() {
        XCTAssertEqual(ScenarioSelection.idsStrippingVariants(["B.s@a", "A", "B.s@b", "B.s"]), ["B.s", "A"])
    }
}

final class RunVariantCarryingTests: XCTestCase {
    func testChildOrientationPrefersTheVariantThenTheProfile() {
        let landscape = ResolvedVariant(name: "l", appearance: .light, textSize: .default, orientation: "landscape")
        let unset = ResolvedVariant(name: "u", appearance: .light, textSize: .default, orientation: nil)
        XCTAssertEqual(Optional(landscape).childOrientation(fallback: .portrait), .landscape)
        XCTAssertEqual(Optional(unset).childOrientation(fallback: .portrait), .portrait)
        XCTAssertNil(Optional(unset).childOrientation(fallback: nil))
        XCTAssertEqual(Optional<ResolvedVariant>.none.childOrientation(fallback: .landscape), .landscape)
    }

    /// 子へ運ぶ値の正: プロファイルの解決結果(`ScenarioExecutionSettings.variants`)を名前で引く
    func testResolvedProfileCarriesVariantsToTheSettings() {
        let variant = ResolvedVariant(name: "dark", appearance: .dark, textSize: .large, orientation: "landscape")
        var profile = ResolvedProfile(
            project: TestProject(name: "dummy", rootURL: URL(fileURLWithPath: "/tmp/dummy")),
            runName: "run", appName: "app", apps: [:], devices: [], fm: FMConfig(), heal: false,
            reportDir: URL(fileURLWithPath: "/tmp/dummy/reports"), defaultTimeout: nil, scenarioTimeout: nil,
            wipeDataOnBloat: true, updateWebView: true, wipeDataThresholdGB: 8, recoverCpuFallbackToGpu: false,
            locale: "ja_JP", iosPreActionPing: true, containerInference: true, ocrTextVisibilityCheck: true,
            preferCheckStateClassifier: true, enableAnimations: false, responseMeasurement: false, responseRepeat: 5,
            homeOnStart: true, playProtectBypass: true, record: false, recordFailuresOnly: false,
            recordBitrateKbps: 1000, recordFullResolution: false, warnings: [])
        profile.variants = [variant]
        XCTAssertEqual(ScenarioExecutionSettings(profile).variants, [variant])
    }
}
