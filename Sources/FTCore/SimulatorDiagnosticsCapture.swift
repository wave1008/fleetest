// iOS Simulator の状態とログを、不具合を検出した時点で1つのテキストへ残す(OI-347 / OI-196 / OI-269 の測る口)。
// 統合ログ(unified log)は端末側に履歴として残るので、検出後に `log show --last` で遡れる(常時の録り続けは要らない)。
// 判定には使わない(記録だけ)。呼び手は**親プロセス**(子はサンドボックスで simctl を直に呼べない)。

import Foundation

public enum SimulatorDiagnosticsCapture {

    /// 外部コマンドの差し替え口(テスト用)。引数と時間上限(秒)を受け、`Shell.run` と同じく非ゼロで投げない
    public typealias CommandRunner = @Sendable (_ args: [String], _ timeout: Double) throws -> Shell.Result

    /// `launchctl list` の時間上限(秒)。根拠: 速い照会で、`SimulatorAppProcess.launchctlListTimeoutSeconds` と同じ 5 秒。
    /// 尽きたら採れなかったと事実だけ書く(回復は待たせない)
    static let launchctlTimeoutSeconds: Double = 5

    /// 統合ログを遡る分数。根拠: 外観を設定してからステップが赤になるまで・起動の180秒の時間切れの手前を含められる長さ。
    /// 長すぎると `log show` が遅くなる(背景で走るので回復は待たせない)
    static let logLookbackMinutes = 10

    /// `log show` の時間上限(秒)。根拠: 起動中の Simulator で 10 分ぶんが約 2 秒(実測)。負荷の下の何十倍かの遅れまで待ち、
    /// 背景のスレッドなので回復は待たせない。尽きたら子ごと止め、ファイルに時間切れと書く(採れた分は無い)
    public static let logShowTimeoutSeconds: Double = 90

    /// 書き出す統合ログの末尾の行数。根拠: 1行約 200 バイトで 1 ファイル約 160 KB に収まる
    static let logTailLines = 800

    /// クラッシュレポートを数える窓(秒)。根拠: OI-196 で SpringBoard の最後の .ips が起動の失敗の約 16 分前だった = 統合ログの
    /// 10 分より前の落ちも名前で拾える長さ。名前の上限は、落ち続ける回でもファイルが一覧で埋まらない数(超えた分は件数だけ書く)
    static let reportWindowSeconds: TimeInterval = 3600
    static let reportListLimit = 20

    /// `log show` の絞り込み。SpringBoard / backboardd のプロセスと、UIKit の外観(UIUserInterfaceStyle 等)に関わる行。
    /// **XCUITest の行(`com.apple.dt.xctest`)は除く**: ランナーが SpringBoard の木を読むたびに SpringBoard の名で何千行も出て、
    /// 末尾 `logTailLines` 行が約1秒ぶんで埋まり、外観の部品(`UserInterfaceStyleArbiter`)の行を押し流した(OI-347・11/25 夜の採取 3 件)
    static let logPredicate = "(process == \"SpringBoard\" OR process == \"backboardd\""
        + " OR eventMessage CONTAINS[c] \"UIUserInterfaceStyle\" OR eventMessage CONTAINS[c] \"appearance\""
        + " OR category == \"UserInterfaceStyleArbiter\") AND NOT (subsystem == \"com.apple.dt.xctest\")"

    /// `launchctl list` から拾う行の語(ラベルに含まれるもの)
    static let launchctlLabelKeywords = ["SpringBoard", "backboardd", "InputUI", "TextInput", "FleetestRunner"]

    /// 結果フォルダの下の置き場の名前(docs/results-json.md)
    public static let directoryName = "diagnostics"

    // MARK: - 置き場と重複抑止

    /// この run の結果フォルダ(`RunRecorder.begin` が入れる)。nil = run の外(呼び手が渡した場所へ書く)。
    /// 1プロセス1 run の前提(同じプロセスで run を重ねるときは後勝ち)
    public static let currentRunDirectory = LockedValue<URL?>(nil)

    /// 置き場・udid・理由ごとの最後の採取の時刻。同じ鍵は統合ログを遡る窓(`logLookbackMinutes`)が過ぎるまで採らない
    /// (窓の中で採り直しても同じ行の重なり。過ぎれば新しい窓 = 常駐プロセスでも2回目の起き方を採れる)
    private static let taken = LockedValue<[String: Date]>([:])

    /// テスト用: 重複抑止の控えを捨てる
    static func resetForTesting() { taken.withLock { $0 = [:] } }

    // MARK: - コマンドの形(テストが固定する)

    static func launchctlCommand(udid: String) -> [String] {
        ["xcrun", "simctl", "spawn", udid, "launchctl", "list"]
    }

    /// 外観の部品(SpringBoard の `UserInterfaceStyleArbiter`)が変更を受けた行だけを長く遡る絞り込み。
    /// 根拠(OI-347): 外観が届かない SpringBoard は、起動の瞬間の1回(`forReason:0`)の後に1度も動いていなかった
    /// (起動から4時間40分)。届く SpringBoard は変更のたびに動く = 壊れた状態は起動の時点で決まり、`logLookbackMinutes` の窓では
    /// 起動まで届かない。1日ぶんでも数十行(行数は `logTailLines` で切らない)・所要は 6 時間ぶんで約 1.8 秒(実測)
    static let arbiterLookbackHours = 24
    static let arbiterPredicate = "category == \"UserInterfaceStyleArbiter\" AND eventMessage CONTAINS \"_updateCurrentStyleAndNotify\""

    static func arbiterLogCommand(udid: String) -> [String] {
        ["xcrun", "simctl", "spawn", udid, "log", "show", "--last", "\(arbiterLookbackHours)h",
         "--style", "compact", "--predicate", arbiterPredicate]
    }

    static func logShowCommand(udid: String) -> [String] {
        ["xcrun", "simctl", "spawn", udid, "log", "show", "--last", "\(logLookbackMinutes)m",
         "--style", "compact", "--predicate", logPredicate]
    }

    // MARK: - 採取

    /// 1回の採取。書いたパスを返す(重複・書けないときは nil)。
    /// - `directory`: 書き先(`diagnostics/` を含まない親)。nil なら `currentRunDirectory`、それも無ければ `fallbackDirectory`
    /// - launchctl とクラッシュレポートは同期で採り(速い)、統合ログは背景で採ってファイルを書き直す。
    ///   集め終えるまでの仮の行は「log not captured yet」で、背景が終わる前にプロセスが終わるとそのまま残る(黙って欠けない)
    /// - 同じ置き場・同じ udid・同じ理由は `logLookbackMinutes` の間に1回だけ
    /// - launchctl の照会は同期(起こし直す前の状態を採るため)。止まった Simulator では時間上限(5 秒 + 子の終了猶予)まで呼び手を待たせうる
    @discardableResult
    public static func capture(
        udid: String, reason: String, directory: URL? = nil, fallbackDirectory: URL? = nil,
        log: (String) -> Void = { _ in }, now: Date = Date(),
        reportsDirectory: URL? = nil, commands: @escaping CommandRunner = { try Shell.run($0, timeout: $1) },
        completion: (@Sendable () -> Void)? = nil
    ) -> URL? {
        guard let parent = directory ?? currentRunDirectory.value ?? fallbackDirectory else { return nil }
        let dir = parent.appendingPathComponent(directoryName)
        let key = dir.path + "|" + udid + "|" + reason
        let window = TimeInterval(logLookbackMinutes * 60)
        let isNew = taken.withLock { map -> Bool in
            if let last = map[key], now.timeIntervalSince(last) < window { return false }
            map[key] = now
            return true
        }
        guard isNew else { return nil }

        let fileName = "\(udid.prefix(8))-\(timestamp(now))-\(reason).txt"
        let url = dir.appendingPathComponent(fileName)
        // 書けなかった回は控えを外す(残すと窓の間の次の起き方まで黙って採らない)
        let release = { _ = taken.withLock { $0.removeValue(forKey: key) } }
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            release()
            log("Simulator diagnostics not saved: \(error.localizedDescription)")
            return nil
        }

        let head = headSection(udid: udid, reason: reason, now: now, reportsDirectory: reportsDirectory,
                               commands: commands)
        let pending = head + "\n== unified log ==\nlog not captured yet (`log show` is still running; if this line remains, the process ended before it finished)\n"
        guard (try? pending.write(to: url, atomically: true, encoding: .utf8)) != nil else {
            release()
            log("Simulator diagnostics not saved: could not write \(url.path)")
            return nil
        }
        log("Simulator diagnostics saved: \(url.path) (the unified log follows)")

        let command = logShowCommand(udid: udid)
        let arbiterCommand = arbiterLogCommand(udid: udid)
        // 古いものを消すのは背景の書き直しを始める前(書き直しの一時ファイルを消さない)
        pruneOldest(in: dir)
        let work: @Sendable () -> Void = {
            let section = logSection(command: command, commands: commands)
            let arbiterHeader = "\n== appearance arbiter (SpringBoard UserInterfaceStyleArbiter, last \(arbiterLookbackHours)h) ==\n"
            // 統合ログの節を先に書く: 外観の部品の 24 時間ぶんは `exitWaitSeconds` の後まで掛かりうるので、その間にプロセスが終わっても
            // 統合ログは仮の行のまま残らない
            try? (head + "\n== unified log ==\n" + section + arbiterHeader
                  + "not captured yet (`log show` is still running; if this line remains, the process ended before it finished)\n")
                .write(to: url, atomically: true, encoding: .utf8)
            let arbiter = arbiterSection(command: arbiterCommand, commands: commands)
            try? (head + "\n== unified log ==\n" + section + arbiterHeader + arbiter)
                .write(to: url, atomically: true, encoding: .utf8)
            completion?()
        }
        // `log show` の子は中断のリレーに載せない: 読む範囲が決まった読み取りだけの子で、親が先に終わっても
        // 時間上限(`logShowTimeoutSeconds`)までに自分で終わる(端末の状態を変えない)
        let thread = Thread { work() }
        thread.name = "fleetest-simulator-diagnostics"
        thread.start()
        return url
    }

    /// `captureOffCooperativePool` が**その採取の**統合ログを書き終えるのを待つ上限(秒)。根拠: `log show` は 10 分ぶんで約 2 秒
    /// (実測)の 5 倍(外観の部品の 24 時間ぶんは含めない = 統合ログの節は先に書く)。尽きたら待たずに進む(ファイルは仮の行のまま = 止まった端末で回復・失敗の報告を延ばさない)。
    /// 待つ理由: 呼び手のプロセスはこの後すぐ終わりうる(起動の時間切れで投げる `bridge up`・回復の直後に終わる run)。
    /// 待たずに終わると背景のスレッドごと消え、ファイルは「log not captured yet」のまま残る
    public static let exitWaitSeconds: TimeInterval = 10

    // MARK: - 節の組み立て

    static func headSection(udid: String, reason: String, now: Date, reportsDirectory: URL?,
                            commands: CommandRunner) -> String {
        var text = "fleetest simulator diagnostics\nudid: \(udid)\nreason: \(reason)\ncaptured-at: \(iso(now))\n"
        text += "\n== launchctl (SpringBoard / backboardd / InputUI / FleetestRunner) ==\n"
        text += launchctlSection(command: launchctlCommand(udid: udid), commands: commands)
        text += "\n== host crash reports in the last \(Int(reportWindowSeconds / 60)) minutes (names only) ==\n"
        text += reportsSection(directory: reportsDirectory ?? defaultReportsDirectory, now: now)
        return text
    }

    static func launchctlSection(command: [String], commands: CommandRunner) -> String {
        do {
            let result = try commands(command, launchctlTimeoutSeconds)
            guard let output = result.outputIfSucceeded else {
                return "not captured: launchctl exited with status \(result.status): \(result.tail)\n"
            }
            let lines = filterLaunchctl(output)
            return lines.isEmpty ? "no matching process lines (PID / last exit status / label)\n"
                : "PID\tstatus\tlabel\n" + lines.joined(separator: "\n") + "\n"
        } catch {
            return "not captured: \(SimulatorSpringBoard.failureDetail(error))\n"
        }
    }

    /// `launchctl list` の行(`PID\tStatus\tLabel`)のうち、ラベルが語を含むもの
    static func filterLaunchctl(_ output: String) -> [String] {
        output.split(separator: "\n").map(String.init).filter { line in
            launchctlLabelKeywords.contains { line.contains($0) }
        }
    }

    static func logSection(command: [String], commands: CommandRunner) -> String {
        do {
            let result = try commands(command, logShowTimeoutSeconds)
            guard let output = result.outputIfSucceeded else {
                return "not captured: log show exited with status \(result.status): \(result.tail)\n"
            }
            // 末尾の改行で空の1行を数えない(見出しの行数と中身を揃える)
            let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            let tail = lines.suffix(logTailLines)
            let header = "last \(logLookbackMinutes)m, predicate: \(logPredicate)\n"
                + "showing the last \(tail.count) of \(lines.count) lines\n"
            return header + tail.joined(separator: "\n") + "\n"
        } catch {
            return "not captured: \(SimulatorSpringBoard.failureDetail(error))\n"
        }
    }

    /// 外観の部品の行を全部書く(切らない)。0 行も事実として書く(起動から1度も動いていない = 起動の行も窓の外)
    static func arbiterSection(command: [String], commands: CommandRunner) -> String {
        do {
            let result = try commands(command, logShowTimeoutSeconds)
            guard let output = result.outputIfSucceeded else {
                return "not captured: log show exited with status \(result.status): \(result.tail)\n"
            }
            let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                .filter { $0.contains("UserInterfaceStyleArbiter") }
            return "predicate: \(arbiterPredicate)\n\(lines.count) line(s)\n"
                + (lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n")
        } catch {
            return "not captured: \(SimulatorSpringBoard.failureDetail(error))\n"
        }
    }

    static var defaultReportsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
    }

    /// ホストの SpringBoard / backboardd の .ips のうち窓の中のもの(名前と時刻だけ。中身は読まない)
    static func reportsSection(directory: URL, now: Date) -> String {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return "not captured: could not list \(directory.path)\n"
        }
        var found: [(name: String, modified: Date)] = []
        for name in names where name.hasSuffix(".ips") && (name.hasPrefix("SpringBoard") || name.hasPrefix("backboardd")) {
            let path = directory.appendingPathComponent(name).path
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) <= reportWindowSeconds else { continue }
            found.append((name, modified))
        }
        guard !found.isEmpty else { return "none\n" }
        let sorted = found.sorted { $0.modified > $1.modified }
        return sorted.prefix(reportListLimit).map { "\(iso($0.modified))  \($0.name)" }.joined(separator: "\n") + "\n"
    }

    // MARK: - 書式

    /// ファイル名の時刻は UTC(中の captured-at・クラッシュレポートの時刻と同じ。機械をまたいで突き合わせる)
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    /// 1つの置き場に残すファイルの上限。根拠: run の外の置き場(`.fleetest/diagnostics/`)は保持容量の掃除の対象外なので、
    /// 1件約 160 KB × 50 = 約 8 MB で頭打ちにする。超えたら古いものから消す(run の結果フォルダは run ごと掃除される)
    static let maxFilesPerDirectory = 50

    /// 書き終えた `.txt` だけ数えて消す(Foundation の書き直しの一時ファイルに触れない)。背景の書き直しがまだありうる新しいもの
    /// (`logShowTimeoutSeconds` 以内)は消さない —— 消しても書き直しが作り直す。そのぶん一時的に上限を超えうる
    static func pruneOldest(in dir: URL, keep: Int = maxFilesPerDirectory, now: Date = Date()) {
        let fm = FileManager.default
        guard let names = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]))?
                .filter({ $0.pathExtension == "txt" }),
              names.count > keep else { return }
        let dated = names.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (url, date) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(keep)
        where now.timeIntervalSince(date) > logShowTimeoutSeconds {
            try? fm.removeItem(at: url)
        }
    }

    /// `capture` を協調スレッドの外で走らせて待つ(async の回復の経路から呼ぶ口)。launchctl の照会は同期で最大 5 秒 + 子の終了猶予
    /// かかるので、協調スレッドを塞がない。起こし直す前の状態を採る順序は保つ(呼び手は待ってから起こし直す)。
    /// 文言は呼び手のスレッドで出す(`log` を別スレッドへ渡さない)
    /// **その採取の**統合ログを書き終えるまで最大 `exitWaitSeconds` 待ってから戻る(他の端末の採取は待たない。失敗・回復の経路だけで、
    /// 通常 2 秒前後延びる)。プロセス全体を待つ口は置かない(run の終わりで協調スレッドを塞ぐ・他の採取まで待つ)
    public static func captureOffCooperativePool(udid: String, reason: String, fallbackDirectory: URL?,
                                                 directory: URL? = nil, reportsDirectory: URL? = nil,
                                                 commands: @escaping CommandRunner = { try Shell.run($0, timeout: $1) }) async
        -> (url: URL?, messages: [String]) {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                let messages = LockedValue<[String]>([])
                let done = DispatchSemaphore(value: 0)
                let url = capture(udid: udid, reason: reason, directory: directory, fallbackDirectory: fallbackDirectory,
                                  log: { line in messages.withLock { $0.append(line) } },
                                  reportsDirectory: reportsDirectory, commands: commands, completion: { done.signal() })
                if url != nil { _ = done.wait(timeout: .now() + exitWaitSeconds) }
                continuation.resume(returning: (url, messages.value))
            }
            thread.name = "fleetest-simulator-diagnostics-head"
            thread.start()
        }
    }

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
