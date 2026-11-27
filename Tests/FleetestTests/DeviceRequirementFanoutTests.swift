// 機械をまたぐ run の台の条件(DR-237 段1a の U6)の規律。デバイス・ssh 不要(偽の remote exec)。
// 破ると: 1機械の観測の失敗が他の機械の台まで読めなくする / 同名の台が別の機械の観測で上書きされる / 子が他の機械の性質を受ける /
// 宣言の無い run が ssh を撃つ / 合う台の無い機械へ宣言付きのシナリオが配られる。

import XCTest
import FTCore
import FTRemote
@testable import fleetest

final class DeviceRequirementFanoutTests: XCTestCase {

    private func entry(_ name: String, platform: String = "ios", physical: Bool = false) -> DeviceMachineGrouping.CatalogEntry {
        DeviceMachineGrouping.CatalogEntry(platform: platform, spec: DeviceSpec(name: name, kind: physical ? .physical : .virtual))
    }

    private func job(_ machine: String?, _ names: [String]) -> DeviceRequirementFanout.Job {
        DeviceRequirementFanout.Job(key: DeviceRequirementTrim.machineKey(machine), machine: machine, profile: "p",
                                    entries: names.map { entry($0) })
    }

    private static let foldableTraits = DeviceTraits(platform: "ios", physical: false, foldable: true)
    private static let plainTraits = DeviceTraits(platform: "ios", physical: false, foldable: false)
    private var foldable: DeviceTraits { Self.foldableTraits }
    private var plain: DeviceTraits { Self.plainTraits }

    // MARK: 観測

    func testRemoteSuccessMergesPerMachineAndSameNameKeepsSeparateTraits() {
        let calls = LockedValue<[String]>([])
        let observed = DeviceRequirementFanout.observe(
            project: "P", jobs: [job(nil, ["sim"]), job("M1", ["sim"])],
            remote: { machine, _, _ in calls.withLock { $0.append(machine) }; return .traits(["sim": Self.foldableTraits]) },
            local: { _ in ["sim": Self.plainTraits] }, log: { _ in })
        XCTAssertEqual(calls.value, ["M1"])
        XCTAssertEqual(observed["local"]?["sim"], plain)
        XCTAssertEqual(observed["M1"]?["sim"], foldable, "同名の台は機械ごとに別の性質")
    }

    /// 失敗はその機械の台だけ platform / physical に落ち(読めなかった)・他の機械は無傷・1行
    func testRemoteFailureIsolatesToThatMachineAndLogsOneLine() {
        let lines = LockedValue<[String]>([])
        let observed = DeviceRequirementFanout.observe(
            project: "P", jobs: [job(nil, ["a"]), job("M1", ["a"]), job("M2", ["b"])],
            remote: { machine, _, _ in
                machine == "M1" ? .failed("exit status 255") : .traits(["b": Self.foldableTraits])
            },
            local: { _ in ["a": Self.foldableTraits] }, log: { line in lines.withLock { $0.append(line) } })
        XCTAssertEqual(observed["M1"]?["a"], DeviceTraits(platform: "ios", physical: false), "失敗した機械は種別だけ確定")
        XCTAssertEqual(observed["local"]?["a"], foldable)
        XCTAssertEqual(observed["M2"]?["b"], foldable)
        XCTAssertEqual(lines.value.count, 1)
        XCTAssertTrue(lines.value[0].contains("M1") && lines.value[0].contains("exit status 255"), lines.value[0])
    }

    func testRemoteMissingDeviceInAnswerFallsBackToUnreadableNotToAnotherDevice() {
        let observed = DeviceRequirementFanout.observe(
            project: "P", jobs: [job("M1", ["a", "b"])],
            remote: { _, _, _ in .traits(["a": Self.foldableTraits]) }, local: { _ in [:] }, log: { _ in })
        XCTAssertEqual(observed["M1"]?["a"], foldable)
        XCTAssertEqual(observed["M1"]?["b"], DeviceTraits(platform: "ios", physical: false))
    }

    func testParseTakesLastJSONLineAmongNoise() {
        let json = #"{"a":{"platform":"ios","physical":false,"foldable":true}}"#
        XCTAssertEqual(DeviceRequirementFanout.parse(stdout: "Warning: x\n\(json)\n")?["a"]?.foldable, true)
        XCTAssertNil(DeviceRequirementFanout.parse(stdout: "nothing"))
    }

    // MARK: 子へ運ぶ

    func testChildGetsOnlyItsOwnMachinesTraitsByPlainName() {
        let observed: MachineDeviceTraits = ["local": ["sim": plain, "x": plain], "M1": ["sim": foldable]]
        XCTAssertEqual(DeviceRequirementCandidacy.childTraits(observed, machine: "M1", deviceNames: ["sim"]), ["sim": foldable])
        XCTAssertEqual(DeviceRequirementCandidacy.childTraits(observed, machine: nil, deviceNames: ["sim"]), ["sim": plain],
                       "グループの台だけ(x は別のグループの台)")
        XCTAssertEqual(DeviceRequirementCandidacy.childTraits(observed, machine: "M2", deviceNames: ["sim"]), [:])
    }

    func testEveryChildPathCarriesTheFlagLocalAndRemote() {
        let traits = ["sim": foldable]
        for host in ["local", "M1"] {
            let args = DeviceMachineRunner.childArgs(
                project: "P", host: host, profile: "p", scenarios: [], folders: [], noLPT: false, lptHistoryRuns: nil,
                performanceMode: false, forceLock: false, remoteDir: nil, remoteTimeout: nil, quiet: false, junitPath: nil,
                deviceTraits: traits)
            XCTAssertEqual(args.firstIndex(of: "--device-traits").flatMap { try? ChildDeviceTraits.decode(args[$0 + 1]) },
                           traits, "run の子(\(host))")
            let none = DeviceMachineRunner.childArgs(
                project: "P", host: host, profile: "p", scenarios: [], folders: [], noLPT: false, lptHistoryRuns: nil,
                performanceMode: false, forceLock: false, remoteDir: nil, remoteTimeout: nil, quiet: false, junitPath: nil)
            XCTAssertFalse(none.contains("--device-traits"), "宣言が無い run は足さない")
        }
        let group = { (machine: String?) in DeviceMachineRunner.Group(machine: machine, deviceNames: ["sim"], platforms: ["ios"]) }
        let options = ApiRunMachineFanout.Options(
            noLPT: false, lptHistoryRuns: nil, performanceMode: false, remoteDir: nil, remoteTimeout: nil)
        for machine in [nil, "M1"] as [String?] {
            let args = ApiRunMachineFanout.buildArgs(
                project: "P", profileName: "p", group: group(machine), units: [], options: options, runGroup: "g",
                deviceTraits: traits)
            XCTAssertEqual(args.firstIndex(of: "--device-traits").flatMap { try? ChildDeviceTraits.decode(args[$0 + 1]) },
                           traits, "api run の子(\(machine ?? "local"))")
        }
        let fleet = FleetRunner.buildArgs(
            project: "P", host: "M1", profile: "p", fleetEntry: false, scenarios: [], folders: [], noLPT: false,
            lptHistoryRuns: nil, performanceMode: false, forceLock: false, remoteDir: nil, remoteTimeout: nil, quiet: false,
            junitPath: nil, deviceTraits: traits)
        XCTAssertTrue(fleet.contains("--device-traits"))
    }

    func testRemoteRunArgsForwardsTheFlagToTheRunnersRun() {
        let json = ChildDeviceTraits.encode(["sim": foldable])
        let run = RemoteRunArgs.build(project: "P", profile: "p", scenarios: [], folders: [], noLPT: false, lptHistoryRuns: nil,
                                      performanceMode: false, remoteJUnitPath: nil, reportDir: nil, deviceTraitsJSON: json)
        XCTAssertEqual(run.firstIndex(of: "--device-traits").map { run[$0 + 1] }, json)
        let api = RemoteRunArgs.buildApi(project: "P", profile: "p", scenarios: [], noLPT: false, lptHistoryRuns: nil,
                                         performanceMode: false, defaultTimeout: nil, scenarioTimeout: nil, reportDir: nil,
                                         deviceTraitsJSON: json)
        XCTAssertEqual(api.firstIndex(of: "--device-traits").map { api[$0 + 1] }, json)
        XCTAssertFalse(RemoteRunArgs.build(project: "P", profile: "p", scenarios: [], folders: [], noLPT: false,
                                           lptHistoryRuns: nil, performanceMode: false, remoteJUnitPath: nil, reportDir: nil)
            .contains("--device-traits"))
    }

    // MARK: 候補

    private func info(_ id: String, _ set: DeviceRequirementSet?, platform: String? = "ios") -> ScenarioInfo {
        ScenarioInfo(id: id, title: id, platform: platform, deviceRequirements: set)
    }

    private let needFold = DeviceRequirementSet(required: [.foldable], excluded: [])

    func testCandidacyGatesByFitAndTreatsUnreadableAsCandidate() {
        let selected = [info("A.fold", needFold), info("A.any", nil)]
        let groups = [
            DeviceMachineRunner.Group(machine: nil, deviceNames: ["sim"], platforms: ["ios"]),
            DeviceMachineRunner.Group(machine: "M1", deviceNames: ["sim"], platforms: ["ios"]),
            DeviceMachineRunner.Group(machine: "M2", deviceNames: ["sim"], platforms: ["ios"]),
        ]
        let observed: MachineDeviceTraits = [
            "local": ["sim": plain], "M1": ["sim": foldable], "M2": ["sim": DeviceTraits(platform: "ios", physical: false)],
        ]
        let c = DeviceRequirementFanout.candidacy(selected: selected, plan: .none, groups: groups, observed: observed,
                                                   defaultPlatform: "ios")
        let fold = ScenarioUnitKey(id: "A.fold", variant: nil)
        XCTAssertFalse(c.isCandidate(fold, entry: 0), "全部読めて合わない")
        XCTAssertTrue(c.isCandidate(fold, entry: 1))
        XCTAssertTrue(c.isCandidate(fold, entry: 2), "読めない台は候補(読めない事実でその機械の子が赤にする)")
        XCTAssertTrue(c.isCandidate(ScenarioUnitKey(id: "A.any", variant: nil), entry: 0), "宣言なしは全エントリ")
        XCTAssertTrue(c.unmet.isEmpty)
    }

    func testNoCandidateAnywhereIsUnmetAndSplitOff() {
        let selected = [info("A.fold", needFold), info("A.any", nil)]
        let groups = [DeviceMachineRunner.Group(machine: nil, deviceNames: ["sim"], platforms: ["ios"])]
        let c = DeviceRequirementFanout.candidacy(selected: selected, plan: .none, groups: groups,
                                                   observed: ["local": ["sim": plain]], defaultPlatform: "ios")
        XCTAssertEqual(c.unmet, [ScenarioUnitKey(id: "A.fold", variant: nil)])
        let (kept, unmet) = c.split(selected)
        XCTAssertEqual(kept.map(\.id), ["A.any"])
        XCTAssertEqual(unmet.map(\.id), ["A.fold"])
        let lines = DeviceRequirementFanout.unmetLines(unmet, facts: c.unmetFacts)
        XCTAssertTrue(lines[0].contains("1 scenario(s)"))
        // 1機械の中の結論と同じく、合わなかった台(機械つき)と理由を言う
        XCTAssertTrue(lines[1].contains("local/sim: unfit (.foldable is required)"), lines[1])
    }

    func testUndeclaredRunIsUnconstrainedAndObservesNothing() {
        XCTAssertFalse(DeviceRequirementFanout.declares([info("A.x", nil), info("A.y", DeviceRequirementSet())]))
        let c = DeviceRequirementFanout.candidacy(selected: [info("A.x", nil)], plan: .none,
                                                   groups: [DeviceMachineRunner.Group(machine: "M1", deviceNames: ["s"], platforms: ["ios"])],
                                                   observed: [:], defaultPlatform: "ios")
        XCTAssertTrue(c.entries.isEmpty && c.unmet.isEmpty)
    }

    /// 観測(= ssh)を撃つ呼び出しは、どの経路も宣言の判定(`declares`)の後ろだけ
    func testEveryObserveCallIsGuardedByDeclares() throws {
        for file in ["DeviceMachineRunner", "ApiRunMachineFanout", "MultiTargetRunner", "FleetRunner"] {
            let text = try String(contentsOfFile: "Sources/fleetest/\(file).swift", encoding: .utf8)
            let observe = try XCTUnwrap(text.range(of: "DeviceRequirementFanout.observe("), file)
            let before = String(text[..<observe.lowerBound])
            let declares = try XCTUnwrap(before.range(of: "DeviceRequirementFanout.declares(", options: .backwards), file)
            XCTAssertLessThan(before.distance(from: declares.lowerBound, to: before.endIndex), 900, "\(file): observe が declares の直後でない")
        }
    }

    // MARK: 静的な割り振り

    func testStaticSplitNeverAssignsDeclaredUnitToNonCandidateEntry() throws {
        let scenarios: [(id: String, variant: String?, platform: String?)] = [
            ("A.fold", nil, "ios"), ("A.a", nil, "ios"), ("A.b", nil, "ios"), ("A.c", nil, "ios"),
        ]
        let fold = ScenarioUnitKey(id: "A.fold", variant: nil)
        let buckets = try FleetSplit.partition(
            scenarios: scenarios, durations: [], entryPlatforms: [["ios"], ["ios"]], unknownDurationMs: 1000,
            candidates: [fold: [1]])
        XCTAssertTrue(buckets[1].units.contains(fold))
        XCTAssertFalse(buckets[0].units.contains(fold))
        // 既定(候補の指定なし)は今までの割り当てと同一
        let plain = try FleetSplit.partition(scenarios: scenarios, durations: [], entryPlatforms: [["ios"], ["ios"]],
                                             unknownDurationMs: 1000)
        let explicit = try FleetSplit.partition(scenarios: scenarios, durations: [], entryPlatforms: [["ios"], ["ios"]],
                                                unknownDurationMs: 1000, candidates: [:])
        XCTAssertEqual(plain, explicit)
    }
}
