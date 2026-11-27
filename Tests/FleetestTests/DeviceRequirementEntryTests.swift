// 台の条件(DR-237)の入口: 一覧まで供給を待つ判定・宣言の文字列の走査・`--port` の台の観測・子へ運ぶ内部フラグ。

import ArgumentParser
import XCTest
import FTBridgeClient
@testable import FTCore
@testable import fleetest

final class DeviceRequirementEntryTests: XCTestCase {

    // MARK: - 待つ判定(純粋関数)

    /// 4通りの全部を固定する: 待つのは「宣言がある」かつ「一覧の前に台を外す」のときだけ
    func testWaitsOnlyWhenDeclaredAndTrimmedBeforeTheListing() {
        typealias E = DeviceRequirementEntry
        XCTAssertEqual(E.supplyStart(sourcesDeclare: true, trimsBeforeListing: true), .waitForListing)
        XCTAssertEqual(E.supplyStart(sourcesDeclare: true, trimsBeforeListing: false), .parallelWithListing)
        XCTAssertEqual(E.supplyStart(sourcesDeclare: false, trimsBeforeListing: true), .parallelWithListing)
        XCTAssertEqual(E.supplyStart(sourcesDeclare: false, trimsBeforeListing: false), .parallelWithListing)
    }

    func testDeclarationMarkersAreTheTwoMacroNames() {
        XCTAssertTrue(DeviceRequirementEntry.sourceDeclares("@RequiresDevice(.foldable)\n@TestClass final class A {}"))
        XCTAssertTrue(DeviceRequirementEntry.sourceDeclares("  @ExcludesDevice(.homeButton)"))
        XCTAssertFalse(DeviceRequirementEntry.sourceDeclares("@TestClass final class A { @Test func t() {} }"))
    }

    private func project(files: [String: String]) throws -> TestProject {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DeviceRequirementEntryTests-\(UUID().uuidString)")
        let project = TestProject(name: "p", rootURL: root)
        try FileManager.default.createDirectory(at: project.scenariosDir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        for (name, text) in files {
            try text.write(to: project.scenariosDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return project
    }

    func testProjectScanFindsDeclarationsInSubfoldersAndIgnoresOtherFiles() throws {
        XCTAssertFalse(DeviceRequirementEntry.sourcesDeclare(project: try project(files: ["a.swift": "@TestClass final class A {}"])))
        XCTAssertTrue(DeviceRequirementEntry.sourcesDeclare(project: try project(files: ["sub/b.swift": "@RequiresDevice(.foldable) class B {}"])))
        XCTAssertFalse(DeviceRequirementEntry.sourcesDeclare(project: try project(files: ["notes.txt": "@RequiresDevice"])))
    }

    /// 入口の関数は宣言が無ければ台の絞り込みを試算しない(回帰の追加コスト = 走査だけ)・broadcast は絞らないので待たない
    func testPreListingStartWaitsOnlyWhenTheTrimDropsDevices() throws {
        let p = try project(files: [:])
        let devices = ["A", "B"].map { ResolvedDevice(platform: "ios", spec: DeviceSpec(name: $0, kind: .physical, udid: "U-\($0)")) }
        let full = ResolvedProfile(
            project: p, runName: "r", appName: "app", apps: [:], devices: devices, fm: FMConfig(), heal: false,
            reportDir: p.rootURL, defaultTimeout: nil, scenarioTimeout: nil, wipeDataOnBloat: true, updateWebView: false,
            wipeDataThresholdGB: 8, recoverCpuFallbackToGpu: false, locale: "ja_JP",
            iosPreActionPing: true, containerInference: true, ocrTextVisibilityCheck: true,
            preferCheckStateClassifier: true, enableAnimations: false, responseMeasurement: false, responseRepeat: 5,
            homeOnStart: true, playProtectBypass: true, record: false, recordFailuresOnly: false,
            recordBitrateKbps: 1500, recordFullResolution: false, warnings: [])
        func start(declares: Bool, count: Int?, broadcast: Bool = false) -> DeviceRequirementEntry.SupplyStart {
            ProfileRunner.preListingSupplyStart(
                project: p, full: full, iosScenarios: count, androidScenarios: count, broadcast: broadcast,
                leaseStateDir: nil, sourcesDeclare: { _ in declares })
        }
        XCTAssertEqual(start(declares: true, count: 1), .waitForListing)          // 2台を1台に絞る
        XCTAssertEqual(start(declares: true, count: nil), .parallelWithListing)   // 絞らない(MCP の印も無い)
        XCTAssertEqual(start(declares: true, count: 5), .parallelWithListing)     // 台数以上 = 絞らない
        XCTAssertEqual(start(declares: false, count: 1), .parallelWithListing)
        XCTAssertEqual(start(declares: true, count: 1, broadcast: true), .parallelWithListing)
    }

    // MARK: - `--port` の台の観測

    private let simctlJSON: [String: Any] = [
        "devicetypes": [["identifier": "T.Duo", "name": "iPhone Duo", "productFamily": "iPhone", "bundlePath": "/nonexistent"]],
        "devices": ["com.apple.CoreSimulator.SimRuntime.iOS-27-2": [["udid": "SIM-1", "deviceTypeIdentifier": "T.Duo"]]],
    ]

    func testPortTraitsReadTheDeviceBehindTheReportedUDID() {
        let traits = DeviceRequirementEntry.portTraits(udid: "SIM-1", physical: false, simctlJSON: simctlJSON, physicalDevices: nil)
        XCTAssertEqual(traits.platform, "ios")
        XCTAssertFalse(traits.physical)
        XCTAssertEqual(traits.model, "iPhone Duo")
    }

    /// udid が無い・一覧に無い台は読めなかった(種別だけ確定 = どの条件も満たさない扱い)
    func testPortTraitsWithoutAUDIDAreUnreadable() {
        XCTAssertEqual(DeviceRequirementEntry.portTraits(udid: nil, physical: false, simctlJSON: simctlJSON, physicalDevices: nil),
                       SimulatorCatalog.unresolvedTraits)
        XCTAssertEqual(DeviceRequirementEntry.portTraits(udid: "NOPE", physical: false, simctlJSON: simctlJSON, physicalDevices: nil),
                       SimulatorCatalog.unresolvedTraits)
        XCTAssertEqual(DeviceRequirementEntry.portTraits(udid: "SIM-1", physical: false, simctlJSON: nil, physicalDevices: nil),
                       SimulatorCatalog.unresolvedTraits)
        XCTAssertEqual(DeviceRequirementEntry.portTraits(udid: nil, physical: true, simctlJSON: nil, physicalDevices: []),
                       IOSPhysicalDeviceTraits.unreadable)
        // 読めなかった台は必須の条件を満たさない(unreadable = 配られない)
        XCTAssertEqual(DeviceRequirementGate.fit(DeviceRequirementSet(required: [.foldable]), traits: SimulatorCatalog.unresolvedTraits),
                       .unreadable(traits: ["foldable"]))
    }

    // MARK: - 子へ運ぶ内部フラグ

    private let sample: [String: DeviceTraits] = [
        "Duo": DeviceTraits(platform: "ios", physical: false, foldable: true, homeButton: false, osVersion: "iOS 27.2", model: "iPhone Duo"),
        "Pixel": DeviceTraits(platform: "android", physical: true),
    ]

    func testChildFlagRoundTrips() throws {
        let args = ChildDeviceTraits.args(sample)
        XCTAssertEqual(args.first, "--device-traits")
        XCTAssertEqual(try ChildDeviceTraits.decode(args[1]), sample)
        XCTAssertEqual(ChildDeviceTraits.args([:]), [])
        XCTAssertThrowsError(try ChildDeviceTraits.decode("not json"))
    }

    /// 両方のコマンドが同じ OptionGroup で受ける(渡し口を片側だけに足さない)・nil = 渡されていない
    func testBothCommandsParseTheFlag() throws {
        let json = ChildDeviceTraits.encode(sample)
        let run = try RunScenarios.parse(["--profile", "p", "--device-traits", json])
        XCTAssertEqual(try run.childTraits.decoded(), sample)
        let api = try ApiRunCommand.parse(["--profile", "p", "--scenario", "A.b", "--device-traits", json])
        XCTAssertEqual(try api.childTraits.decoded(), sample)
        XCTAssertNil(try RunScenarios.parse(["--profile", "p"]).childTraits.decoded())
    }

    /// 子の引数の組み立て: 手元の子だけに載る・空なら載らない
    func testLocalChildArgsCarryTheTraitsOnly() {
        let with = FleetRunner.buildArgs(
            project: "p", host: "local", profile: "r", fleetEntry: false, scenarios: [], folders: [],
            noLPT: false, lptHistoryRuns: nil, performanceMode: false, forceLock: false, remoteDir: nil,
            remoteTimeout: nil, quiet: false, junitPath: nil, deviceTraits: sample)
        let i = with.firstIndex(of: "--device-traits")
        XCTAssertNotNil(i)
        XCTAssertEqual(i.flatMap { try? ChildDeviceTraits.decode(with[$0 + 1]) }, sample)
        let without = FleetRunner.buildArgs(
            project: "p", host: "local", profile: "r", fleetEntry: false, scenarios: [], folders: [],
            noLPT: false, lptHistoryRuns: nil, performanceMode: false, forceLock: false, remoteDir: nil,
            remoteTimeout: nil, quiet: false, junitPath: nil)
        XCTAssertFalse(without.contains("--device-traits"))
        // リモートの機械の子(中継役)へは載せない(別の段)
        let remote = FleetRunner.buildArgs(
            project: "p", host: "M1", profile: "r", fleetEntry: false, scenarios: [], folders: [],
            noLPT: false, lptHistoryRuns: nil, performanceMode: false, forceLock: false, remoteDir: nil,
            remoteTimeout: nil, quiet: false, junitPath: nil, deviceTraits: sample)
        XCTAssertFalse(remote.contains("--device-traits"))
    }
}
