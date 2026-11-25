// `RunTunables` は `ScenarioExecutionSettings` に乗って型で守られる区間を通るが、子プロセス境界
// (ScenarioHost の `--tunables` ⇄ ScenarioRunnerMain の復号と使用)だけは型検査が効かない。
// ここが欠けるとプロファイルの値が子に届かず黙って既定で走るので、走査で固定する。
// JSON の往復そのものは RunTunablesBoundaryTests(FTDSLTests)が見る。

import XCTest
@testable import FTCore

final class RunTunablesWiringTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// 折り返しで落ちないよう空白を畳んでから見る
    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// `RunTunables` の欄に写されていて、実行時は `tunables.<欄>` で解く `FlowStep` の既定。
    /// 欄を足したら `RunTunables` の init の既定値に `FlowStep.<定数>` を書き、ここへも足す(下の走査テストが突き合わせる)
    private static let tunableBackedConstants = ["defaultWaitSeconds", "defaultMaxSwipes", "defaultSwipeDurationSeconds",
                                                 "defaultFlickDurationSeconds", "defaultFlickIntervalSeconds",
                                                 "defaultPinchDurationSeconds", "defaultHoldSeconds",
                                                 "defaultIsScreenWaitSeconds"]

    /// `FlowStep` の既定のうち tunables に欄が無い固定値。理由は1行
    private static let fixedConstants: [String: String] = [
        "defaultTapHoldSeconds": "タップの保持。DSL の引数 holdSeconds が直接持つ(プロファイルの欄なし)",
        "defaultMaxEdgeSwipes": "端までのスクロールの上限。欄なし(maxSwipes とは別の意味)",
        "defaultDragPressSeconds": "ドラッグの押下時間。ジェスチャ合成の内部定数で欄なし",
        "defaultPinchOutScale": "pinchOut の倍率。DSL の引数 scale が持つ",
        "defaultPinchInScale": "pinchIn の倍率。DSL の引数 scale が持つ",
    ]

    private func codeLines(_ path: String) throws -> [String] {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
            .components(separatedBy: "\n").map { $0.components(separatedBy: "//")[0] }
    }

    /// `FlowStep` の `static let default…` を Sources から集め、tunables の欄に写されるものと固定値の表へ漏れなく分ける。
    /// 写されるものは `RunTunables` の init が既定値に使う `FlowStep.<定数>`(+ `DefaultWait.seconds` = defaultWaitSeconds)から導く
    func testEveryFlowStepDefaultIsClassifiedAsTunableOrFixed() throws {
        let declared = Set(try codeLines("Sources/FTCore/Flow.swift").compactMap { line -> String? in
            guard let range = line.range(of: #"static let (default\w+)"#, options: .regularExpression) else { return nil }
            return String(line[range].dropFirst("static let ".count))
        })
        XCTAssertGreaterThanOrEqual(declared.count, 10, "FlowStep の既定の走査が拾えていない")
        let tunables = try codeLines("Sources/FTCore/RunTunables.swift")
        var backed = Set(tunables.flatMap { line -> [String] in
            line.components(separatedBy: "FlowStep.").dropFirst().compactMap { rest in
                let name = String(rest.prefix { $0.isLetter || $0.isNumber })
                return name.hasPrefix("default") ? name : nil
            }
        })
        if tunables.contains(where: { $0.contains("DefaultWait.seconds") }) { backed.insert("defaultWaitSeconds") }
        XCTAssertEqual(backed, Set(Self.tunableBackedConstants),
                       "RunTunables が既定に使う FlowStep の定数の集合が表(tunableBackedConstants)と違う —— 欄を足した/外したなら"
                       + "表と、StepExecutor・DSL の `?? FlowStep.<定数>` を禁じる2つのテストの対象を揃える。差分: "
                       + "\(backed.symmetricDifference(Set(Self.tunableBackedConstants)).sorted())")
        XCTAssertEqual(declared.subtracting(backed), Set(Self.fixedConstants.keys),
                       "FlowStep に tunables の欄が無い既定が増減した。足したなら欄を作る(RunTunables)か、固定値として"
                       + " fixedConstants へ理由付きで足す。差分: "
                       + "\(declared.subtracting(backed).symmetricDifference(Set(Self.fixedConstants.keys)).sorted())")
    }

    func testScenarioHostAlwaysForwardsTheTunables() throws {
        let host = try source("Sources/FTCore/ScenarioHost.swift")
        XCTAssertTrue(host.contains("let tunables = settings.tunables"), "settings の tunables を読んでいない")
        XCTAssertTrue(host.contains("args += [\"--tunables\", try tunablesArgument(tunables)]"),
                      "--tunables を子へ渡していない(プロファイルの値が子に届かない)")
    }

    func testScenarioRunnerMainUsesTheDecodedTunables() throws {
        let runner = try source("Sources/FTScenarioRunner/ScenarioRunnerMain.swift")
        XCTAssertTrue(runner.contains("customLong(\"tunables\")"), "--tunables を受け取れない")
        XCTAssertTrue(runner.contains("let runTunables = try Self.decodeTunables(tunables)"),
                      "--tunables を復号していない")
        XCTAssertTrue(runner.contains("timeoutSeconds: runTunables.injectedAppProbeTimeout"),
                      "起動時プローブの締切に injectedAppProbeTimeout を使っていない")
        XCTAssertTrue(runner.contains("probe.status(timeout: runTunables.injectedAppProbeTimeout)"),
                      "起動時プローブの status の締切に injectedAppProbeTimeout を使っていない")
        XCTAssertTrue(runner.contains("tunables: runTunables,"), "FTDriveCore へ tunables を渡していない")
    }

    /// 実行時に解決する既定は `tunables.<欄>`。固定値へ戻すとプロファイル(将来のキー)で変えても
    /// StepExecutor だけ古い値で動く
    func testStepExecutorNeverFallsBackToTheFixedDefaults() throws {
        let dir = Self.repoRoot.appendingPathComponent("Sources/FTCore")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("StepExecutor") && $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(files.count, 5, "走査が StepExecutor のファイルに届いていない")
        let constants = Self.tunableBackedConstants
        for constant in constants {
            let offenders = try files.filter {
                try source("Sources/FTCore/\($0)").contains("?? FlowStep.\(constant)")
            }
            XCTAssertEqual(offenders, [], "固定値 FlowStep.\(constant) へのフォールバックが残っている(tunables を使う)")
        }
    }

    /// DSL の既定引数は nil にして `core.tunables` で解く。`= FlowStep.<定数>` の既定引数や
    /// `?? FlowStep.<定数>` が戻ると、その引数だけ実行時の既定に追随しなくなる
    func testDSLNeverBakesInTheFixedDefaults() throws {
        let dir = Self.repoRoot.appendingPathComponent("Sources/FTDSL")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(files.count, 5, "走査が FTDSL のファイルに届いていない")
        let constants = Self.tunableBackedConstants
        for file in files {
            let text = try source("Sources/FTDSL/\(file)")
            for constant in constants {
                XCTAssertFalse(text.contains("= FlowStep.\(constant)") || text.contains("?? FlowStep.\(constant)"),
                               "\(file): FlowStep.\(constant) を既定に焼き込んでいる(core.tunables を使う)")
            }
        }
    }

    func testDriveCoreHandsTheTunablesToTheExecutor() throws {
        let runtime = try source("Sources/FTDSL/FTRuntime.swift")
        XCTAssertTrue(runtime.contains("tunables: tunables,"), "StepExecutor へ tunables を渡していない")
        XCTAssertTrue(runtime.contains("FTSync.apply(tunables)"),
                      "commandTimeout・commandCancelUnwindSeconds を DSL の締切へ反映していない")
        let sync = try source("Sources/FTDSL/FTSync.swift")
        XCTAssertTrue(sync.contains("commandTimeout = tunables.commandTimeout"), "FTSync.apply が commandTimeout を写していない")
        XCTAssertTrue(sync.contains("cancelUnwindGraceSeconds = tunables.commandCancelUnwindSeconds"),
                      "FTSync.apply が止まり切る待ちを写していない(親の無出力の監視の上限と食い違う)")
        XCTAssertTrue(runtime.contains("commandTimeoutSeconds: tunables.commandTimeout"),
                      "StepExecutor の締切が tunables と別の出どころになっている")
    }
}
