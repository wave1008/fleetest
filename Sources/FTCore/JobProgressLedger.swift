// ジョブ(予定の run の一覧と、それぞれの状態)の機械グローバルな台帳(DS-18)。
//
// run ボードに出るのは走っている run だけなので、run を順に何本も起こすスクリプトや複数対象の run で
// 「あと何本控えているか」が見えない。run の上に1階層だけジョブを置き、控えの run を pending として並べる。
// **fleetest はジョブを実行しない**(見える化の台帳だけ)。入れ子もタスクも作らない。
//
// 置き場は ~/.fleetest/jobs/<jobID>.json(RunProgressLedger と同じ理由で機械グローバル)。
// 持ち主(ownerPid)の生死は pid + startedAt の照合(`ProcessLiveness.isAliveAndNotStartedAfter`。mtime は見ない)。
// **書き込みはすべてベストエフォート**(失敗で run を止めない)。行の更新は複数プロセス(スクリプトの子 run・
// 複数対象の親)から並行に来るので、read-modify-write は `<jobID>.lock` の flock で直列化する。

import Foundation

public enum JobRunState: String, Codable, Sendable {
    case pending, running, passed, failed, canceled, skipped

    public var isTerminal: Bool { self != .pending && self != .running }
}

public struct JobRunEntry: Codable, Equatable, Sendable {
    public var project: String
    public var profile: String
    public var state: JobRunState
    /// 複数対象の run が担当マシン名を入れる(手元は "local")。単発の run は空
    public var machines: [String]
    /// 単発の run が自分を running にしたときの pid(読み手が死を見て canceled と読むため)。それ以外は nil
    public var pid: Int32?

    public init(project: String, profile: String, state: JobRunState, machines: [String] = [], pid: Int32? = nil) {
        self.project = project
        self.profile = profile
        self.state = state
        self.machines = machines
        self.pid = pid
    }
}

public struct JobProgressRecord: Codable, Equatable, Sendable {
    public let jobID: String
    public let title: String
    public let issuer: String?
    public let ownerPid: Int32
    /// ISO8601 UTC
    public let startedAt: String
    public var runs: [JobRunEntry]

    public init(jobID: String, title: String, issuer: String?, ownerPid: Int32, startedAt: String, runs: [JobRunEntry]) {
        self.jobID = jobID
        self.title = title
        self.issuer = issuer
        self.ownerPid = ownerPid
        self.startedAt = startedAt
        self.runs = runs
    }
}

/// 行の印付けの規則(純粋関数)
public enum JobRunMarking {
    /// 同じ project:profile の行を更新する。running にするときは pending の行を優先(無ければ走っている行 = 別マシンが加わる)、
    /// それ以外は終端でない最初の行。該当が無ければ末尾に足す(宣言していない run も事実として載せる)。
    /// machines は重複なく追加。pid は終端で外す
    public static func mark(
        runs: inout [JobRunEntry], project: String, profile: String, state: JobRunState,
        machine: String? = nil, pid: Int32? = nil
    ) {
        let same = runs.indices.filter { runs[$0].project == project && runs[$0].profile == profile }
        let index: Int?
        if state == .running {
            index = same.first { runs[$0].state == .pending } ?? same.first { runs[$0].state == .running }
        } else {
            index = same.first { !runs[$0].state.isTerminal }
        }
        guard let index else {
            runs.append(JobRunEntry(project: project, profile: profile, state: state,
                                    machines: machine.map { [$0] } ?? [], pid: state.isTerminal ? nil : pid))
            return
        }
        runs[index].state = state
        if let machine, !runs[index].machines.contains(machine) { runs[index].machines.append(machine) }
        if state.isTerminal {
            runs[index].pid = nil
        } else if let pid {
            runs[index].pid = pid
        }
    }
}

public enum JobProgressLedger {
    public static func directory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".fleetest", isDirectory: true)
            .appendingPathComponent("jobs", isDirectory: true)
    }

    /// ジョブを作って台帳へ書く。開始時に死んだ持ち主の控えを1回掃く(読み手に掃除を置かない = RunProgressLedger.sweep と同じ)。
    /// 書けなくても record は返す(run を止めない)
    @discardableResult
    public static func begin(
        title: String, ownerPid: Int32, runs: [JobRunEntry], issuer: String?,
        directory: URL = directory(),
        isAlive: (Int32) -> Bool = ProcessLiveness.isAlive,
        startTime: (Int32) -> Date? = ProcessLiveness.startTime
    ) -> JobProgressRecord {
        sweep(directory: directory, isAlive: isAlive, startTime: startTime)
        let record = JobProgressRecord(
            jobID: UUID().uuidString, title: title, issuer: issuer, ownerPid: ownerPid,
            startedAt: ISO8601DateFormatter().string(from: Date()), runs: runs)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        write(record, directory: directory)
        return record
    }

    /// flock の内側で読み → body → 書く。ファイルが無ければ何もしない(リモート側・終わったジョブ)
    public static func update(jobID: String, directory: URL = directory(), _ body: (inout JobProgressRecord) -> Void) {
        guard isValidID(jobID) else { return }
        let url = fileURL(jobID: jobID, directory: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let fd = open(lockURL(jobID: jobID, directory: directory).path, O_CREAT | O_NOFOLLOW | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            return
        }
        guard let data = try? Data(contentsOf: url),
              var record = try? JSONDecoder().decode(JobProgressRecord.self, from: data) else { return }
        body(&record)
        write(record, directory: directory)
    }

    /// 行の印付け(`JobRunMarking.mark`)を flock の下で1回行う
    public static func mark(
        jobID: String, project: String, profile: String, state: JobRunState,
        machine: String? = nil, pid: Int32? = nil, directory: URL = directory()
    ) {
        update(jobID: jobID, directory: directory) {
            JobRunMarking.mark(runs: &$0.runs, project: project, profile: profile, state: state,
                               machine: machine, pid: pid)
        }
    }

    public static func remove(jobID: String, directory: URL = directory()) {
        guard isValidID(jobID) else { return }
        try? FileManager.default.removeItem(at: fileURL(jobID: jobID, directory: directory))
        try? FileManager.default.removeItem(at: lockURL(jobID: jobID, directory: directory))
    }

    /// 生きている持ち主のジョブだけ返す(pid + startedAt の照合)。壊れた JSON は1件だけ飛ばす
    public static func readAll(
        directory: URL = directory(), isAlive: (Int32) -> Bool = ProcessLiveness.isAlive,
        startTime: (Int32) -> Date? = ProcessLiveness.startTime
    ) -> [JobProgressRecord] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var records: [JobProgressRecord] = []
        for name in names where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let record = try? JSONDecoder().decode(JobProgressRecord.self, from: data) else { continue }
            guard ownerAlive(record, isAlive: isAlive, startTime: startTime) else { continue }
            records.append(record)
        }
        return records
    }

    /// 死んだ持ち主の .json と、対の .json が無い .lock を消す。中身が読めない .json は触らない(この台帳が作った物とは限らない)
    public static func sweep(
        directory: URL, isAlive: (Int32) -> Bool = ProcessLiveness.isAlive,
        startTime: (Int32) -> Date? = ProcessLiveness.startTime
    ) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let jsons = Set(names.filter { $0.hasSuffix(".json") })
        for name in names {
            let url = directory.appendingPathComponent(name)
            if name.hasSuffix(".json") {
                guard let data = try? Data(contentsOf: url),
                      let record = try? JSONDecoder().decode(JobProgressRecord.self, from: data),
                      !ownerAlive(record, isAlive: isAlive, startTime: startTime) else { continue }
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(
                    at: lockURL(jobID: String(name.dropLast(".json".count)), directory: directory))
            } else if name.hasSuffix(".lock"), !jsons.contains(String(name.dropLast(".lock".count)) + ".json") {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func ownerAlive(_ record: JobProgressRecord, isAlive: (Int32) -> Bool,
                                   startTime: (Int32) -> Date?) -> Bool {
        guard let recordedAt = ISO8601DateFormatter().date(from: record.startedAt) else {
            return isAlive(record.ownerPid)
        }
        return ProcessLiveness.isAliveAndNotStartedAfter(
            record.ownerPid, recordedAt: recordedAt, isAliveOverride: isAlive, startTimeOverride: startTime)
    }

    /// ID は環境変数・引数から来るのでパスの部品にできる形(英数字と `-`)だけ通す(`../` で台帳の外を触らせない)
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 }
    }

    private static func fileURL(jobID: String, directory: URL) -> URL {
        directory.appendingPathComponent("\(jobID).json")
    }

    private static func lockURL(jobID: String, directory: URL) -> URL {
        directory.appendingPathComponent("\(jobID).lock")
    }

    /// 一時ファイル → rename のアトミック書き込み(RunProgressLedger.write と同じ)
    private static func write(_ record: JobProgressRecord, directory: URL) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        let tmp = directory.appendingPathComponent(".\(record.jobID).\(UUID().uuidString).tmp")
        guard (try? data.write(to: tmp)) != nil else { return }
        guard rename(tmp.path, fileURL(jobID: record.jobID, directory: directory).path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            return
        }
    }
}
