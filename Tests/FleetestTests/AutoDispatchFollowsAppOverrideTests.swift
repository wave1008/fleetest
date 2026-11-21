// `--set app=` は対象の OS を変え、どのデバイスが走るかを変える(ProfileResolver.runDeviceMachines の overrides の宣言)。
// 機械分担の計画(DeviceMachineRunner.plan)と自動ディスパッチの判定(resolveEffectiveDispatchTarget)が同じ上書きを見ないと、
// 計画は「1機械」と言い、自動ディスパッチは「機械をまたぐ」と言って、どちらも引き取らずに手元で走る

import XCTest
import FTCore
@testable import fleetest

final class AutoDispatchFollowsAppOverrideTests: XCTestCase {
    var tempDir: URL!
    var project: TestProject!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FleetestTests-\(UUID().uuidString)")
        project = TestProject(name: "SampleApp", rootURL: tempDir.appendingPathComponent("TestProjects/SampleApp"))
        for dir in [project.runsDir, project.appsDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try #"{ "platform": "hybrid", "ios": { "app": "com.example.a" }, "android": { "app": "com.example.a" } }"#
            .data(using: .utf8)!.write(to: project.appsDir.appendingPathComponent("both.json"))
        try #"{ "platform": "ios", "ios": { "app": "com.example.ios" } }"#
            .data(using: .utf8)!.write(to: project.appsDir.appendingPathComponent("iosOnly.json"))
        // iOS は runner1・Android は手元。プロファイルの app は両 OS
        try """
        { "app": "both", "devices": [
          { "platform": "ios", "machine": "runner1", "name": "リモートの iPhone" },
          { "platform": "android", "machine": "local", "name": "手元の Android" } ] }
        """.data(using: .utf8)!.write(to: project.runsDir.appendingPathComponent("mixed.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// `--set app=iosOnly` で走るのは runner1 の iPhone だけ = 機械分担は要らず、runner1 へ自動で送る
    func testAnAppOverrideThatLeavesOneRemoteMachineAutoDispatchesThere() throws {
        let overrides: [String: RunProfileSetValue] = ["app": .string("iosOnly")]
        XCTAssertNil(try DeviceMachineRunner.plan(project: project, profileName: "mixed", explicitHost: nil,
                                                  deviceFilter: [], disabledMachines: [], overrides: overrides),
                     "上書き後は1機械なので機械分担の計画は作らない")
        let target = try resolveEffectiveDispatchTarget(
            explicitTarget: nil, profile: "mixed", project: nil, requireProfileMachine: true,
            overrides: overrides, testProject: project)
        XCTAssertEqual(target?.rawTarget, "runner1", "計画が引き取らない回は、自動ディスパッチが上書き後の唯一の機械へ送る")
    }

    /// 上書きが無ければ2機械にまたがる = 機械分担が引き取り、自動ディスパッチはしない(既存の挙動)
    func testWithoutTheOverrideTheMixedProfileIsSplitByMachine() throws {
        XCTAssertEqual(try DeviceMachineRunner.plan(project: project, profileName: "mixed", explicitHost: nil,
                                                    deviceFilter: [], disabledMachines: [])?.count, 2)
        XCTAssertNil(try resolveEffectiveDispatchTarget(
            explicitTarget: nil, profile: "mixed", project: nil, requireProfileMachine: true,
            overrides: [:], testProject: project))
    }
}
