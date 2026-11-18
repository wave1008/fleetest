// run がジョブの行を自動で受け持つ(JobProgressLedger の読み手側の約束)。
//
// 環境変数 `FT_JOB_ID` = 所属するジョブ・`FT_JOB_MARKED` = このプロセスの祖先がすでにその行を受け持っている印。
// 入口の `claim` は ID があって印が無いときだけ行を running(pid = 自分)にし、印を立てて子孫へ継がせる。
// 子孫(機械分担の子・リモートの子・`--work-queue` の子)は ID だけを持ち(`RunProgressRecord.jobID`)行は触らない ——
// 1本の run が行を二重に更新しないため。台帳が無ければ(リモート側・終わったジョブ)黙って何もしない。
// 呼び手は `fleetest run` と `fleetest api run` の2経路(終了コードが確定する場所で `finish`)。複数対象の run は
// ここを通らず MultiTargetRunner が行を受け持つ。

import Foundation

public enum JobMembership {
    public static let jobIDKey = "FT_JOB_ID"
    public static let markedKey = "FT_JOB_MARKED"

    public struct Claim: Equatable, Sendable {
        public let jobID: String
        public let project: String
        public let profile: String
        public let directory: URL
    }

    private static let current = LockedValue<Claim?>(nil)

    public static func jobIDFromEnvironment() -> String? {
        guard let raw = getenv(jobIDKey) else { return nil }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }

    /// 終了コード → 行の状態。0 = passed・130(中断)= canceled・それ以外 = failed
    public static func state(forExitCode code: Int32) -> JobRunState {
        switch code {
        case 0: return .passed
        case 130: return .canceled
        default: return .failed
        }
    }

    /// run の入口で呼ぶ。受け持ったら Claim を返し、印を立てる(`setMarked` はテストの差し替え口)
    @discardableResult
    public static func claim(
        project: String, profile: String,
        jobID: String? = jobIDFromEnvironment(),
        alreadyMarked: Bool = getenv(markedKey) != nil,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        directory: URL = JobProgressLedger.directory(),
        setMarked: () -> Void = { setenv(markedKey, "1", 1) }
    ) -> Claim? {
        guard let jobID, !alreadyMarked else { return nil }
        let claim = Claim(jobID: jobID, project: project, profile: profile, directory: directory)
        JobProgressLedger.mark(jobID: jobID, project: project, profile: profile, state: .running,
                               pid: pid, directory: directory)
        setMarked()
        interrupted.withLock { $0 = false }   // 印はこの claim の run のもの(受け持つ前の印を持ち越さない)
        current.withLock { $0 = claim }
        return claim
    }

    private static let interrupted = LockedValue(false)

    /// run が中断で終わったことを記録する(`RunRecorder.finish` の interrupted)。中断した run の終了コードは
    /// 失敗の有無で 0 / 1 になるので、終了コードだけでは成功・失敗に化ける
    public static func noteInterrupted() {
        interrupted.withLock { $0 = true }
    }

    /// 終了コードが確定する場所で呼ぶ。claim していなければ何もしない(2回呼んでも1回目だけ効く)。
    /// 中断の印があれば終了コードより先に canceled
    public static func finish(exitCode: Int32) {
        guard let claim = current.withLock({ c -> Claim? in defer { c = nil }; return c }) else { return }
        let wasInterrupted = interrupted.withLock { value -> Bool in defer { value = false }; return value }
        JobProgressLedger.mark(jobID: claim.jobID, project: claim.project, profile: claim.profile,
                               state: wasInterrupted ? .canceled : state(forExitCode: exitCode),
                               directory: claim.directory)
    }
}
