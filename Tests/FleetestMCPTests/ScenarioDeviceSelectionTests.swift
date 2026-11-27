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
        guard case .run(let chosen, let runnable, let skipped, _)? = result else { return XCTFail("\(String(describing: result))") }
        XCTAssertEqual(chosen, 1)
        XCTAssertEqual(runnable.map(\.id), ["A.t"])
        XCTAssertTrue(skipped.isEmpty)
    }

    func testFirstFittingDeviceWinsOnTies() {
        let result = ScenarioDeviceSelection.select(infos: [info("A.t", foldableSet)], candidates: {
            [.init(name: "phone", traits: self.phone), .init(name: "duoA", traits: self.duo), .init(name: "duoB", traits: self.duo)]
        })
        guard case .run(let chosen, _, _, _)? = result else { return XCTFail() }
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
        guard case .run(_, let runnable, let skipped, _)? = result else { return XCTFail("\(String(describing: result))") }
        XCTAssertEqual(runnable.map(\.id), ["A.plain"])
        XCTAssertEqual(skipped.map(\.id), ["A.fold"])
        XCTAssertTrue(ScenarioDeviceSelection.skippedLines(skipped)[0].hasPrefix("⏭ A.fold: not applicable"))
    }

    /// 選んだ台に合わないテストを別の候補が満たすなら「合う台が無い」(緑の対象外)と言わず、その台を名指して未実行にする
    func testTestAnotherCandidateFitsIsDeferredNotSkipped() {
        let result = ScenarioDeviceSelection.select(
            infos: [info("A.t1", foldableSet),
                    info("A.t2", DeviceRequirementSet(excluded: [.foldable])),
                    info("A.t3", DeviceRequirementSet(excluded: [.foldable]))],
            candidates: { [.init(name: "duo", traits: self.duo), .init(name: "phone", traits: self.phone)] })
        guard case .run(let chosen, let runnable, let skipped, let deferred)? = result else {
            return XCTFail("\(String(describing: result))")
        }
        XCTAssertEqual(chosen, 1, "2本が合う phone を選ぶ")
        XCTAssertEqual(runnable.map(\.id), ["A.t2", "A.t3"])
        XCTAssertTrue(skipped.isEmpty, "別の台が合うテストを対象外にした: \(skipped)")
        XCTAssertEqual(deferred.map(\.id), ["A.t1"])
        XCTAssertEqual(deferred.map(\.device), ["duo"])
        let line = ScenarioDeviceSelection.deferredLines(deferred)[0]
        XCTAssertTrue(line.contains("needs device duo"), line)
        XCTAssertFalse(line.contains("no matching device"), line)
    }

    /// 選んだ台に合わず、他の候補に読めない台が居るなら(その台が合うかもしれない)緑の対象外にせずエラー
    func testUnreadableOtherCandidateBlocksTheSkip() {
        var blind = duo
        blind.foldable = nil
        let result = ScenarioDeviceSelection.select(
            infos: [info("A.t1", foldableSet), info("A.t2", DeviceRequirementSet(excluded: [.foldable]))],
            candidates: { [.init(name: "blind", traits: blind), .init(name: "phone", traits: self.phone)] })
        guard case .unreadable? = result else { return XCTFail("\(String(describing: result))") }
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
