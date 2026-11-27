// `fleetest api macho-check <file>`: 手元から送られた実行ファイルがこの機械で動くかを Mach-O のヘッダだけで見る内部口
// (`remote align` がランナーで撃つ。`RemoteAlignPlan.buildScript` の `ft_install` が使う)。何も起動しない。
// 動くなら stdout に `ok` で exit 0・動かない/読めないなら理由を stdout に1行出して exit 1。

import ArgumentParser
import Foundation
import FTCore

struct ApiMachOCheckCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macho-check",
        abstract: "Check that an executable file matches this machine's CPU and macOS version (reads the Mach-O header only)",
        shouldDisplay: false)

    @Argument(help: "Path of the executable to check")
    var file: String

    /// 判定 → (動くか, 1行)。`ScenarioHost.usePrebuilt` と同じ `MachOCompatibility.check` を通す
    static func describe(_ verdict: MachOCompatibility.Verdict) -> (ok: Bool, line: String) {
        switch verdict {
        case .compatible: return (true, "ok")
        case .unreadable: return (false, "not readable as a macOS executable")
        case .wrongArchitecture(let have, let want):
            return (false, "built for \(have.joined(separator: "/")) but this machine is \(want)")
        case .osTooNew(let required, let host):
            return (false, "needs macOS \(required) but this machine runs \(host)")
        }
    }

    func run() throws {
        let result = Self.describe(MachOCompatibility.check(file: URL(fileURLWithPath: file)))
        ConsoleOut.out(result.line)
        if !result.ok { throw ExitCode.failure }
    }
}
