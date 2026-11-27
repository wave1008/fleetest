// `fleetest api prebuild-scenarios --project P ...`: 複数プロジェクトのシナリオを1回の swift build でまとめて作り、指紋を残す内部口。
// 回帰(`Scripts/regress.py`)が段1と並行に起こし、段2の親の同じ先行ビルドを「変更なし」で抜けさせる。デバイスには触らない。
// まとめたビルドの失敗は exit 1(呼び手は無視してよい = 段2が1本ずつ作る)。

import ArgumentParser
import Foundation
import FTCore

struct ApiPrebuildScenariosCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prebuild-scenarios",
        abstract: "Build the scenarios of several projects in one swift build (internal; used by Scripts/regress.py)",
        shouldDisplay: false)

    @Option(name: .customLong("project"), help: "Test project name (repeatable)")
    var projects: [String] = []

    func run() throws {
        guard !projects.isEmpty else { throw ValidationError("--project is required") }
        var seen: Set<String> = []
        let resolved = try projects.filter { seen.insert($0).inserted }.map { try ScenarioHost.project(named: $0) }
        if !ScenarioHost.prebuildTogether(projects: resolved, log: { ConsoleOut.err($0) }) { throw ExitCode.failure }
    }
}
