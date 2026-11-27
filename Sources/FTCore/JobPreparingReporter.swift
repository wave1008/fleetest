// 複数対象の run で、ディスパッチの子が機械の準備の段階を台帳(`JobProgressRecord.preparing`)へ書く。
// 子は親から `FT_JOB_ID` を継ぐ。ジョブが無い(単発の `--runner` run)・台帳が無いときは nil / 何もしない。
// 書き込みはすべてベストエフォート(失敗で run を止めない)。

import Foundation

public struct JobPreparingReporter: Sendable {
    public let jobID: String
    public let machine: String
    public let project: String
    public let profile: String
    public let directory: URL

    public init(jobID: String, machine: String, project: String, profile: String,
                directory: URL = JobProgressLedger.directory()) {
        self.jobID = jobID
        self.machine = machine
        self.project = project
        self.profile = profile
        self.directory = directory
    }

    /// ジョブ(`FT_JOB_ID`)が無い・machine が無いときは nil
    public static func fromEnvironment(
        machine: String?, project: String, profile: String,
        jobID: String? = JobMembership.jobIDFromEnvironment(), directory: URL = JobProgressLedger.directory()
    ) -> JobPreparingReporter? {
        guard let jobID, let machine, !machine.isEmpty else { return nil }
        return JobPreparingReporter(jobID: jobID, machine: machine, project: project, profile: profile,
                                    directory: directory)
    }

    public func enter(_ stage: JobPreparingStage) {
        JobProgressLedger.setPreparing(
            jobID: jobID, machine: machine,
            activity: JobPreparingActivity(stage: stage, project: project, profile: profile), directory: directory)
    }

    /// 自分(この project/profile)が置いた段階だけ消す
    public func clear() {
        JobProgressLedger.setPreparing(jobID: jobID, machine: machine, activity: nil,
                                       onlyFor: (project, profile), directory: directory)
    }
}
