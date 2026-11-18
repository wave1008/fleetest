// `fleetest job begin/end` — run を順に何本も起こすスクリプト向けのジョブの宣言(JobProgressLedger)。
// 宣言した run は run ボードに「控え」として出る。fleetest はジョブを実行しない(見える化の台帳だけ)。
// 以降に同じシェルから起こす `fleetest run` は `FT_JOB_ID` を見て自分の行を受け持つ(JobMembership)。

import ArgumentParser
import FTCore
import Foundation

struct JobCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "job",
        abstract: "Declare a job (a list of planned runs) so the run board shows runs that are still waiting",
        discussion: """
        Usage in a script:
          FT_JOB_ID=$(fleetest job begin --title "e2e" --owner-pid $$ --run App:ios --run App:android)
          export FT_JOB_ID
          fleetest run --project App --profile ios
          fleetest job end --id "$FT_JOB_ID"
        """,
        subcommands: [Begin.self, End.self])

    struct Begin: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a job and print its ID")

        @Option(help: "Job title shown on the run board")
        var title: String

        @Option(name: .customLong("owner-pid"),
                help: "PID of the process that owns the job (the script's $$); the job disappears when it dies")
        var ownerPid: Int32

        @Option(name: .customLong("run"), help: "Planned run as <project>:<profile> (repeatable)")
        var runs: [String] = []

        func validate() throws {
            if ownerPid <= 0 { throw ValidationError("--owner-pid must be a positive PID") }
            for spec in runs { _ = try Self.parse(spec) }
        }

        static func parse(_ spec: String) throws -> JobRunEntry {
            let parts = spec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw ValidationError("--run must be <project>:<profile> (got \"\(spec)\")")
            }
            return JobRunEntry(project: parts[0], profile: parts[1], state: .pending)
        }

        func run() throws {
            let record = JobProgressLedger.begin(
                title: title, ownerPid: ownerPid, runs: try runs.map(Self.parse),
                issuer: LocalConfig.resolveIssuerId())
            ConsoleOut.out(record.jobID)
        }
    }

    struct End: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a job from the board")

        @Option(help: "Job ID printed by `job begin`")
        var id: String

        func run() throws {
            JobProgressLedger.remove(jobID: id)
        }
    }
}
