// シミュレータの SpringBoard を起こし直す。**前面のアプリと XCUITest ランナーも一緒に落ちる**(実測: マップのプロセスが消え、
// ランナーの /status が答えなくなった)ので、呼び手はランナーを作り直し、アプリを起動し直す時点でだけ撃つ。
// 呼び手は2つ: 残ったシステムアラートの3段目(`ProfileWorkerFactory.respringAndRebuild`)と、劣化したランナーの回復
// (`BridgeProvisioner.restartRunner`)。SpringBoard の劣化(`/systemalert` の1問が 3.5s 前後)はランナーの起動し直しでは
// 直らず、SpringBoard の起こし直しで 0.11〜0.18s に戻った(実測・起こし直し約 8s)

import Foundation

public enum SimulatorSpringBoard {

    /// 撃つコマンド(テストが形を固定する)。`system/` は非推奨の警告を出すが動く(exit 0。実測)
    public static func command(udid: String) -> [String] {
        ["xcrun", "simctl", "spawn", udid, "launchctl", "kickstart", "-k", "system/com.apple.SpringBoard"]
    }

    /// `restart` の時間切れ(秒)。根拠: 起こし直しは約 8s(実測)で、遅い機械でもその数倍に収まる。
    /// 尽きたら simctl を子ごと止めて失敗とし、detail に時間切れと言う
    static let restartTimeoutSeconds: Double = 30

    /// 起こし直す。**終了コードで成否を返す**(Shell.run は非ゼロで投げない)。detail は失敗の末尾
    public static func restart(udid: String) -> (ok: Bool, detail: String) {
        do {
            let result = try Shell.run(command(udid: udid), timeout: restartTimeoutSeconds)
            return (result.status == 0, result.tail)
        } catch {
            return (false, failureDetail(error))
        }
    }

    /// 撃てなかった理由。時間切れ(子を止めた)と、撃てなかった(起動の失敗など)を分けて言う
    public static func failureDetail(_ error: Error) -> String {
        if case ShellError.timedOut(_, let seconds) = error {
            return "simctl did not finish within \(Int(seconds))s (killed)"
        }
        return "simctl did not run: \(error.localizedDescription)"
    }
}

// MARK: - 落ち続けているかの判定(蘇生の入口で使う。`ProfileRunOrchestrator` の reviveWorker)

extension SimulatorSpringBoard {
    /// `launchctl list` の SpringBoard の1行。`pid` nil = 動いていない。`lastExit` = 前回の終了状態(負 = シグナル。-5 = SIGTRAP)
    public struct Reading: Sendable, Equatable {
        public let pid: Int?
        public let lastExit: Int
        public init(pid: Int?, lastExit: Int) { self.pid = pid; self.lastExit = lastExit }
    }

    public enum CrashLoopVerdict: Sendable, Equatable {
        /// 窓の中で pid が `restarts` 回変わり、前回の終了状態が異常のまま
        case crashing(restarts: Int, lastExit: Int)
        /// 異常終了の後、窓の間ずっと動いていない
        case stopped(lastExit: Int)
        /// 落ち続けているとは言えない(一度落ちただけ・意図した起こし直しを含む)
        case healthy
        /// 1回も読めなかった(判定材料なし = 止めない)
        case unreadable

        public var isUnusable: Bool {
            switch self { case .crashing, .stopped: return true
            case .healthy, .unreadable: return false }
        }

        public var description: String {
            switch self {
            case .crashing(let restarts, let lastExit):
                return "SpringBoard restarted \(restarts) time(s) in \(Int(SimulatorSpringBoard.crashLoopWindowSeconds))s"
                    + " and keeps exiting abnormally (last exit status \(lastExit))"
            case .stopped(let lastExit):
                return "SpringBoard exited abnormally (status \(lastExit)) and did not come back"
                    + " for \(Int(SimulatorSpringBoard.crashLoopWindowSeconds))s"
            case .healthy: return "SpringBoard is running normally"
            case .unreadable: return "SpringBoard's state could not be read"
            }
        }
    }

    /// 読む窓(秒)と間隔(秒)。根拠: 開いた iPhone Duo の落ち続けは 12〜20 秒おき(11/6〜11/19 の実測・OI-184)なので、
    /// 45 秒あれば2回以上の入れ替わりを見られる。入れ替わりがそれより遅いと `healthy` と読む = 止めずに今までどおり蘇生する
    public static let crashLoopWindowSeconds: Double = 45
    public static let crashLoopIntervalSeconds: Double = 3
    /// 落ち続けと言う入れ替わりの回数(1回は意図した起こし直し・単発の落ちと区別できない)
    public static let crashLoopMinRestarts = 2

    public static func listCommand(udid: String) -> [String] {
        ["xcrun", "simctl", "spawn", udid, "launchctl", "list"]
    }

    /// `launchctl list` の出力(`PID\tStatus\tLabel`)から SpringBoard の行を読む。行が無い・形が違えば nil
    public static func parse(launchctlList output: String) -> Reading? {
        for line in output.split(separator: "\n") {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 3, cols[2] == "com.apple.SpringBoard", let status = Int(cols[1]) else { continue }
            if cols[0] == "-" { return Reading(pid: nil, lastExit: status) }
            guard let pid = Int(cols[0]) else { return nil }
            return Reading(pid: pid, lastExit: status)
        }
        return nil
    }

    /// 採った読みの並び(nil = その回は読めなかった)から判定する
    public static func crashLoopVerdict(_ readings: [Reading?]) -> CrashLoopVerdict {
        let read = readings.compactMap { $0 }
        guard let last = read.last else { return .unreadable }
        guard last.lastExit != 0 else { return .healthy }
        if read.allSatisfy({ $0.pid == nil }) { return .stopped(lastExit: last.lastExit) }
        var restarts = 0
        var previous: Int?
        for pid in read.compactMap(\.pid) {
            if let previous, previous != pid { restarts += 1 }
            previous = pid
        }
        return restarts >= crashLoopMinRestarts ? .crashing(restarts: restarts, lastExit: last.lastExit) : .healthy
    }

    /// 1回読む(終了コードが非ゼロ・行が無ければ nil)
    public static func read(udid: String) -> Reading? {
        guard let output = (try? Shell.run(listCommand(udid: udid), timeout: restartTimeoutSeconds))?.outputIfSucceeded else { return nil }
        return parse(launchctlList: output)
    }

    /// 落ち続けているかを測る。**最初の1回で前回の終了状態が 0 なら窓を払わずに `healthy`**(落ちたことの無い台は 0.3 秒ほどで返る)
    /// `onWatch` は窓を払い始めるときに1回だけ呼ぶ(呼び手が「なぜ待つか」を記録に出す。最初の読み = nil なら読めなかった)
    public static func probeCrashLoop(udid: String, reader: (String) -> Reading? = SimulatorSpringBoard.read(udid:),
                                      onWatch: (Reading?) -> Void = { _ in }) async -> CrashLoopVerdict {
        let first = reader(udid)
        if let first, first.lastExit == 0 { return .healthy }
        onWatch(first)
        var readings: [Reading?] = [first]
        let count = Int(crashLoopWindowSeconds / crashLoopIntervalSeconds)
        for _ in 1..<count {
            try? await Task.sleep(nanoseconds: UInt64(crashLoopIntervalSeconds * 1_000_000_000))
            // 取り消されたら判定しない: 落ち続けの最中は起き直す間だけ pid が無いので、窓に満たない読みは「止まったまま」と誤る
            if Task.isCancelled { return .unreadable }
            readings.append(reader(udid))
        }
        return crashLoopVerdict(readings)
    }
}
