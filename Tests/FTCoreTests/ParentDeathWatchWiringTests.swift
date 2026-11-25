// ParentDeathWatch の配線をソース走査で固定する。
//
// **武装するのは spawn 側が `FT_PARENT_PID` を渡した子だけ**(既定は no-op)。Sources 全体から
// 「`Process()` 等で子を起こし、自分の実行ファイルの位置を引くファイル」を拾い、①鍵を渡す ②鍵を消す
// ③どちらでもない(理由付きの例外)に分けて、それぞれ手書きの表と等号で比べる。
// 新しい起こし元は表のどこかへ足さない限り落ちる。

import XCTest
@testable import FTCore

final class ParentDeathWatchWiringTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// fleetest / fleetest-scenarios を子として起こし、`FT_PARENT_PID` を渡すファイル(Sources からの相対)。
    /// 経路を足したら `ParentDeathWatch.childEnvironment()` を通してここへ足す
    private static let armedSpawnSites: Set<String> = [
        "FTCore/ScenarioHost.swift",
        "FTCore/VisionHelperHost.swift",
        "fleetest/ApiRunMachineFanout.swift",
        "fleetest/RemoteDeviceFanout.swift",
        "fleetest/RemoteMonitorFanout.swift",
        "fleetest/FleetRunner.swift",
        "fleetest-mcp/MCPServer+RunJobs.swift",
        // `MCPRunJobs.childEnvironment`(= ParentDeathWatch.childEnvironment を土台にする)を通す
        "fleetest-mcp/MCPServer+Services.swift",
    ]

    /// 親の死を生き延びる子のため `FT_PARENT_PID` を**消す**ファイル(process-lifecycle.md の例外4つ。
    /// 鍵を渡す経路と取り違えないよう別の表にする)
    private static let keyStrippingSites: Set<String> = [
        "FTCore/FMServe.swift",                      // api fm-serve: run を跨いで常駐
        "FTCore/IOSSimulatorVideoRecorder.swift",    // api recorder-watch: 親より長く client を見張る
        "fleetest/RunCompletionSweep.swift",         // 背景の掃除: 親の run は掃除より先に終わる
        "fleetest/ServicesOwnerLaunch.swift",        // services の所有者: 親(CLI)より長く生きる
    ]

    /// 子を起こして実行ファイルの位置を引くが、fleetest を子に持たない(鍵を渡す必要が無い)ファイル。理由は1行
    private static let nonFleetestSpawners: [String: String] = [
        "FTCore/HostRecordingProbe.swift": "simctl recordVideo の試験起動。見張りの起動は IOSSimulatorVideoRecorder.watcherLaunch(鍵を消す側)",
        "FTCore/RegionText.swift": "/usr/bin/sample を起こすだけ(compile-ocr は子プロセスではない)",
        "fleetest/RemoteAlign.swift": "ssh / scp。fleetest の位置は転送元の指定に引くだけ",
        "fleetest/RemoteProjectSync.swift": "rsync。selfBinaryPath の定義元",
        "fleetest/ServicesSession.swift": "docker 等の外部コマンド。所有者の復元は ServicesOwnerLaunch(鍵を消す側)へ委ねる",
        "fleetest/RunHookRunner.swift": "run-setup / teardown スクリプト。実行ファイルの位置は PATH へ fleetest-services を足すためだけ",
    ]

    private struct Scan { var spawners: Set<String> = [], armed: Set<String> = [], stripping: Set<String> = [] }

    /// Sources 全体を走査する(コメントを除いたコード行だけを見る)
    private func scan() throws -> Scan {
        let root = Self.repoRoot.appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let spawn = ["Process()", "SignalDefaultProcess.launch", "posix_spawn"]
        let locator = ["ExecutablePath.current", "ExecutablePath.resolved", "selfBinaryPath(",
                       "CommandLine.arguments[0]", "fleetest-scenarios", ".build/debug/fleetest", "\"fleetest\""]
        var result = Scan()
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let code = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
                .map { $0.components(separatedBy: "//")[0] }
            let keyLines = code.filter { $0.contains("ParentDeathWatch.environmentKey") }
            if keyLines.contains(where: { $0.contains("] = nil") || $0.contains("removeValue") }) {
                result.stripping.insert(relative)
            }
            let arms = code.contains { $0.contains("ParentDeathWatch.childEnvironment(")
                                          || $0.contains("DispatchTicketIssuer.childEnvironment(")
                                          || $0.contains("MCPRunJobs.childEnvironment(") }
                || keyLines.contains { $0.contains("environmentKey] =") && !$0.contains("environmentKey] = nil") }
            let joined = code.joined(separator: "\n")
            if spawn.contains { joined.contains($0) } && locator.contains { joined.contains($0) } {
                result.spawners.insert(relative)
                if arms { result.armed.insert(relative) }
            }
        }
        return result
    }

    /// 子を起こす経路を Sources から拾い、鍵を渡す表・鍵を消す表・例外の表と等号で比べる
    func testEverySpawnSiteIsClassifiedAndArmedOrExempt() throws {
        let scan = try scan()
        XCTAssertGreaterThanOrEqual(scan.spawners.count, 12, "起こし元の走査が拾えていない —— 走査の前提が崩れた")
        XCTAssertEqual(scan.armed, Self.armedSpawnSites,
                       "FT_PARENT_PID を渡す起こし元の集合が表と違う —— fleetest の子を起こす経路を足したなら"
                       + " ParentDeathWatch.childEnvironment() を通して armedSpawnSites へ足す(渡さないと孤児が残る)。"
                       + " 差分: \(scan.armed.symmetricDifference(Self.armedSpawnSites).sorted())")
        XCTAssertEqual(scan.stripping, Self.keyStrippingSites,
                       "FT_PARENT_PID を消すファイルの集合が表と違う —— 親の死を生き延びる子を足すなら"
                       + " process-lifecycle.md の例外へ名指しで足し keyStrippingSites へも足す。"
                       + " 差分: \(scan.stripping.symmetricDifference(Self.keyStrippingSites).sorted())")
        let unclassified = scan.spawners.subtracting(scan.armed).subtracting(Self.keyStrippingSites)
        XCTAssertEqual(unclassified, Set(Self.nonFleetestSpawners.keys),
                       "子を起こすファイルが鍵を渡しても消してもいない。fleetest を起こすなら"
                       + " ParentDeathWatch.childEnvironment() を通し、起こさないなら理由付きで nonFleetestSpawners へ足す。"
                       + " 差分: \(unclassified.symmetricDifference(Set(Self.nonFleetestSpawners.keys)).sorted())")
    }

    /// `fleetest` / `fleetest-scenarios` の2エントリポイントが起動時に武装すること
    func testBothEntryPointsArmOnStartup() throws {
        let entryPoints = [
            "Sources/FTScenarioRunner/ScenarioRunnerMain.swift",
            "Sources/fleetest/Fleetest.swift",
        ]
        for path in entryPoints {
            let text = try source(path)
            XCTAssertTrue(text.contains("ParentDeathWatch.armIfRequested"),
                          "\(path) が起動時に武装していない(FT_PARENT_PID を渡されても孤児化を防げない)")
        }
    }

    /// MCP の stdio サーバは印が無くても起動した親を見張る(応答の読み手は親だけ。処理中は stdin を読まないので
    /// EOF では長い待ちの最中の親の死に気づけない)
    func testMCPServerArmsOnTheLaunchingParent() throws {
        let text = try source("Sources/fleetest-mcp/MCPServer.swift")
        XCTAssertTrue(text.contains("ParentDeathWatch.armOnLaunchingParent()"),
                      "fleetest-mcp が起動時に親を見張っていない(親が死んでも長い待ちの間 PPID 1 で残る)")
    }
}
