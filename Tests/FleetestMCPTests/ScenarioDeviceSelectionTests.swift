// ft_run_scenario の台選び(DR-237): 条件に合う台を選び、合わないテストを名指しし、読めなければ赤、宣言が無ければ観測しない。

import XCTest
import FTCore
@testable import fleetest_mcp

final class ScenarioDeviceSelectionTests: XCTestCase {

    private let foldableSet = DeviceRequirementSet(required: [.foldable])
    private let phone = DeviceTraits(platform: "ios", physical: false, foldable: false, homeButton: false,
                                     osVersion: "iOS 27.2", model: "iPhone 17")
    private let duo = DeviceTraits(platform: "ios", physical: false, foldable: true, homeButton: false,
                                   osVersion: "iOS 27.2", model: "iPhone Duo")

    private func info(_ id: String, _ set: DeviceRequirementSet? = nil) -> ScenarioInfo {
        ScenarioInfo(id: id, title: "", platform: "ios", deviceRequirements: set)
    }

    func testPicksTheFittingDeviceNotTheFirst() {
        let result = ScenarioDeviceSelection.select(infos: [info("A.t", foldableSet)], candidates: {
            [.init(name: "phone", traits: self.phone), .init(name: "duo", traits: self.duo)]
        })
        guard case .run(let chosen, let runnable, let skipped)? = result else { return XCTFail("\(String(describing: result))") }
        XCTAssertEqual(chosen, 1)
        XCTAssertEqual(runnable.map(\.id), ["A.t"])
        XCTAssertTrue(skipped.isEmpty)
    }

    func testFirstFittingDeviceWinsOnTies() {
        let result = ScenarioDeviceSelection.select(infos: [info("A.t", foldableSet)], candidates: {
            [.init(name: "phone", traits: self.phone), .init(name: "duoA", traits: self.duo), .init(name: "duoB", traits: self.duo)]
        })
        guard case .run(let chosen, _, _)? = result else { return XCTFail() }
        XCTAssertEqual(chosen, 1)
    }

    func testNoneFitAllReadableIsNotApplicableWithFacts() {
        let result = ScenarioDeviceSelection.select(infos: [info("A.t", foldableSet)], candidates: {
            [.init(name: "phone", traits: self.phone)]
        })
        guard case .nothingApplicable(let skipped)? = result else { return XCTFail("\(String(describing: result))") }
        XCTAssertEqual(skipped.map(\.id), ["A.t"])
        XCTAssertTrue(skipped[0].reason.contains("phone: unfit"), skipped[0].reason)
    }

    func testUnreadableIsAnErrorNotASkip() {
        var unreadable = phone
        unreadable.foldable = nil
        let result = ScenarioDeviceSelection.select(infos: [info("A.t", foldableSet)], candidates: {
            [.init(name: "phone", traits: unreadable)]
        })
        guard case .unreadable(let message)? = result else { return XCTFail("\(String(describing: result))") }
        XCTAssertTrue(message.contains("phone: unreadable (foldable)"), message)
    }

    func testUnobservedDeviceIsUnreadable() {
        let result = ScenarioDeviceSelection.select(infos: [info("A.t", foldableSet)], candidates: {
            [.init(name: "phone", traits: nil)]
        })
        guard case .unreadable? = result else { return XCTFail("\(String(describing: result))") }
    }

    func testMixedClassRunsFittingTestsAndNamesTheOthers() {
        let result = ScenarioDeviceSelection.select(
            infos: [info("A.plain"), info("A.fold", foldableSet)],
            candidates: { [.init(name: "phone", traits: self.phone)] })
        guard case .run(_, let runnable, let skipped)? = result else { return XCTFail("\(String(describing: result))") }
        XCTAssertEqual(runnable.map(\.id), ["A.plain"])
        XCTAssertEqual(skipped.map(\.id), ["A.fold"])
        XCTAssertTrue(ScenarioDeviceSelection.skippedLines(skipped)[0].hasPrefix("⏭ A.fold: not applicable"))
    }

    func testMixedClassWithUnreadableForASkippedTestIsAnError() {
        var unreadable = phone
        unreadable.foldable = nil
        let result = ScenarioDeviceSelection.select(
            infos: [info("A.plain"), info("A.fold", foldableSet)],
            candidates: { [.init(name: "phone", traits: unreadable)] })
        guard case .unreadable? = result else { return XCTFail("\(String(describing: result))") }
    }

    func testUndeclaredScenariosAreNeverObserved() {
        var observed = 0
        let result = ScenarioDeviceSelection.select(
            infos: [info("A.t"), info("A.u", DeviceRequirementSet())],
            candidates: { observed += 1; return [] })
        XCTAssertNil(result)
        XCTAssertEqual(observed, 0)
    }

    func testDeclaredScenarioObservesOncePerCall() {
        var observed = 0
        _ = ScenarioDeviceSelection.select(infos: [info("A.t", foldableSet)], candidates: {
            observed += 1
            return [.init(name: "duo", traits: self.duo)]
        })
        XCTAssertEqual(observed, 1)
    }

    /// 配線: 直指定は観測して同じ判定にかける・プロファイルは台名で選ぶ・台の判定は Gate だけ
    func testWiring() throws {
        let code = try MCPServerSourceText.combined()
        XCTAssertTrue(code.contains("ScenarioDeviceSelection.directCandidate(directConnection)"))
        XCTAssertTrue(code.contains("deviceName: chosenDeviceName"))
        XCTAssertTrue(code.contains("DeviceRequirementGate.fit"))
        XCTAssertFalse(code.contains("DeviceRequirementMatch.fit("))
    }
}
