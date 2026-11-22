// api monitor の周期から、PosterBoard が落ち続けている Simulator の検出と停止(DS-12.4.5・DR-217)を切り離す。
// 周期は scheduleIfDue() を呼ぶだけ(待たない)。.ips の走査と simctl は背景の Task が行い、結果は log へ流す
// (モニターの出力 NDJSON には新しい行種を足さない = ワイヤ形式・ProtocolVersion を変えない。stderr の1行)。
// 前例: BridgeLogRotationSampler / DeviceStorageSampler。

import FTAndroid
import Foundation

final class PosterBoardCrashLoopSampler: @unchecked Sendable {
    /// 読む間隔(秒)。しきい値に届いてから止めるまでの遅れの上限 = この秒数(窓 1800 秒の 1/15)。
    /// .ips の列挙と simctl 一覧は軽くないので周期ごと(数秒)には読まない
    static let intervalSeconds: TimeInterval = 120

    typealias Enforce = @Sendable () async -> [PosterBoardCrashLoopGuard.Report]

    /// lastRunAt / running / warnedInUse を守る
    private let lock = NSLock()
    private var lastRunAt: Date?
    private var running = false
    /// 使用中で止めなかった台のうち警告を出した UDID。同じ台を毎回言わない(判定から外れたら忘れる)
    private var warnedInUse: Set<String> = []
    private let now: @Sendable () -> Date
    private let enforce: Enforce
    private let log: @Sendable (String) -> Void

    /// テストの差し替え口。本番は `init(log:)`
    init(now: @escaping @Sendable () -> Date = { Date() }, enforce: @escaping Enforce,
         log: @escaping @Sendable (String) -> Void) {
        self.now = now
        self.enforce = enforce
        self.log = log
    }

    convenience init(log: @escaping @Sendable (String) -> Void) {
        self.init(enforce: { await PosterBoardCrashLoopGuard.enforce(log: { _ in }) }, log: log)
    }

    /// 呼び手は毎周期これを呼ぶ(待たない)。間隔が経っていて、前回が終わっていれば背景で1回回す。
    /// **due の判定と印の更新は同じロックの中**
    func scheduleIfDue() {
        lock.lock()
        let due = !running && (lastRunAt == nil || now().timeIntervalSince(lastRunAt!) >= Self.intervalSeconds)
        if due { running = true; lastRunAt = now() }
        lock.unlock()
        guard due else { return }
        Task.detached(priority: .utility) { [self] in
            let reports = await enforce()
            for line in linesToLog(reports) { log(line) }
        }
    }

    /// 出す行を決める(止めた・止められなかった台は毎回、使用中の台は判定の間に1回)。`running` もここで下ろす
    func linesToLog(_ reports: [PosterBoardCrashLoopGuard.Report]) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        running = false
        var inUse: Set<String> = []
        var lines: [String] = []
        for report in reports {
            if case .skippedInUse = report.action {
                inUse.insert(report.udid)
                guard !warnedInUse.contains(report.udid) else { continue }
            }
            lines.append(PosterBoardCrashLoopGuard.message(report))
        }
        warnedInUse = inUse
        return lines
    }
}
