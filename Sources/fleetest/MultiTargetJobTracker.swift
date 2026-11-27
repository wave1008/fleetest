// 複数対象の run(MultiTargetRunner)がジョブの行を受け持つ(FTCore.JobMembership の複数対象版)。
// 外側のジョブ(`FT_JOB_ID`)があればその行を使い、無ければ自分でジョブを作って終わりに消す。
// 子へ `FT_JOB_ID` と `FT_JOB_MARKED=1` を継がせる(子の run は行を受け持たない)。
// 外側がすでに行を受け持っている(`FT_JOB_MARKED`)ときは作らない(nil)。行の更新はすべてベストエフォート。

import FTCore
import Foundation

struct MultiTargetJobTracker: Sendable {
    let jobID: String
    let ownsJob: Bool
    let directory: URL
    /// running の行に入れる pid(この複数対象の run の親)。SIGKILL されたとき監視が canceled と読めるように
    let pid: Int32
    /// running にしてまだ終端にしていない対象(project:profile)。外側のジョブを借りているとき、出口で閉じるのはこれだけ
    /// (外側の全行を閉じると、この run の後で回す予定の行 = regress.py の証人まで canceled になる)
    private let open = LockedValue<Set<String>>([])

    private static func key(_ project: String, _ profile: String) -> String { "\(project)\u{1}\(profile)" }

    /// targets = (project 名, profile 名)。`setEnvironment` はテストの差し替え口(既定は setenv)
    static func begin(
        targets: [(project: String, profile: String)], issuer: String? = LocalConfig.resolveIssuerId(),
        directory: URL = JobProgressLedger.directory(),
        outerJobID: String? = JobMembership.jobIDFromEnvironment(),
        outerMarked: Bool = getenv(JobMembership.markedKey) != nil,
        ownerPid: Int32 = ProcessInfo.processInfo.processIdentifier,
        setEnvironment: (String, String) -> Void = { setenv($0, $1, 1) }
    ) -> MultiTargetJobTracker? {
        if outerMarked { return nil }
        let jobID: String
        let owns: Bool
        if let outerJobID {
            jobID = outerJobID
            owns = false
        } else {
            let runs = targets.map { JobRunEntry(project: $0.project, profile: $0.profile, state: .pending) }
            jobID = JobProgressLedger.begin(title: "run", ownerPid: ownerPid, runs: runs, issuer: issuer,
                                            directory: directory).jobID
            owns = true
            setEnvironment(JobMembership.jobIDKey, jobID)
        }
        setEnvironment(JobMembership.markedKey, "1")
        return MultiTargetJobTracker(jobID: jobID, ownsJob: owns, directory: directory, pid: ownerPid)
    }

    func running(project: String, profile: String, machine: String) {
        open.withLock { _ = $0.insert(Self.key(project, profile)) }
        JobProgressLedger.mark(jobID: jobID, project: project, profile: profile, state: .running,
                               machine: machine, pid: pid, directory: directory)
    }

    /// 機械の準備中の段階を置く(子のディスパッチは `JobPreparingReporter` で同じ欄を書く。ここは親側の口)
    func preparing(machine: String, stage: JobPreparingStage, project: String, profile: String) {
        JobProgressLedger.setPreparing(
            jobID: jobID, machine: machine,
            activity: JobPreparingActivity(stage: stage, project: project, profile: profile), directory: directory)
    }

    /// 終端にする対象の準備中の段階は残さない(子が途中で死ぬと自分では消せない)。
    /// 次の対象が同じ機械へ置いた段階は project/profile が違うので消さない
    func mark(project: String, profile: String, state: JobRunState) {
        if state.isTerminal {
            open.withLock { _ = $0.remove(Self.key(project, profile)) }
            Self.clearPreparing(of: project, profile, jobID: jobID, directory: directory)
        }
        JobProgressLedger.mark(jobID: jobID, project: project, profile: profile, state: state, directory: directory)
    }

    private static func clearPreparing(of project: String, _ profile: String, jobID: String, directory: URL) {
        JobProgressLedger.update(jobID: jobID, directory: directory) { record in
            record.preparing = record.preparing.filter { !($0.value.project == project && $0.value.profile == profile) }
        }
    }

    /// 出口の安全網。自分のジョブなら消す(終端でない行も一緒に消える)。外側のジョブを借りているときは、
    /// running にしたまま閉じていない自分の対象の行だけを canceled にする(他の行 = 外側の予定には触らない)
    func closeOut() {
        if ownsJob {
            JobProgressLedger.remove(jobID: jobID, directory: directory)
            return
        }
        let left = open.withLock { keys -> Set<String> in defer { keys = [] }; return keys }
        guard !left.isEmpty else { return }
        JobProgressLedger.update(jobID: jobID, directory: directory) { record in
            for key in left {
                let parts = key.split(separator: "\u{1}", maxSplits: 1, omittingEmptySubsequences: false)
                record.preparing = record.preparing.filter {
                    !($0.value.project == String(parts[0]) && $0.value.profile == String(parts[1]))
                }
                JobRunMarking.mark(runs: &record.runs, project: String(parts[0]), profile: String(parts[1]),
                                   state: .canceled)
            }
        }
    }

    /// 対象の終わりの状態。既存の成否の判定(子の終了コード・配られなかったシナリオ・中断)をそのまま読む
    static func finalState(codes: [Int32], started: Bool, hasUnhanded: Bool, interrupted: Bool) -> JobRunState {
        if !started { return interrupted ? .canceled : .failed }
        let failing = codes.contains { $0 != 0 } || hasUnhanded
        if !failing { return .passed }
        return interrupted ? .canceled : .failed
    }
}
