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

    /// `log show` の時間上限(秒)。根拠: 起動中の Simulator で 10 分ぶんが約 2 秒(2026-11-25 実測)。負荷の下の何十倍かの遅れまで待ち、
    /// 背景のスレッドなので回復は待たせない。尽きたら子ごと止め、ファイルに時間切れと書く(採れた分は無い)
    static let logShowTimeoutSeconds: Double = 90

    /// 書き出す統合ログの末尾の行数。根拠: 1行約 200 バイトで 1 ファイル約 160 KB に収まる
    static let logTailLines = 800

    /// クラッシュレポートを数える窓(秒)。根拠: OI-196 で SpringBoard の最後の .ips が起動の失敗の約 16 分前だった = 統合ログの
    /// 10 分より前の落ちも名前で拾える長さ。名前の上限は、落ち続ける回でもファイルが一覧で埋まらない数(超えた分は件数だけ書く)
    static let reportWindowSeconds: TimeInterval = 3600
    static let reportListLimit = 20

    /// `log show` の絞り込み。SpringBoard / backboardd のプロセスと、UIKit の外観(UIUserInterfaceStyle 等)に関わる行
    static let logPredicate = "process == \"SpringBoard\" OR process == \"backboardd\""
        + " OR eventMessage CONTAINS[c] \"UIUserInterfaceStyle\" OR eventMessage CONTAINS[c] \"appearance\""

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

    static func logShowCommand(udid: String) -> [String] {
        ["xcrun", "simctl", "spawn", udid, "log", "show", "--last", "\(logLookbackMinutes)m",
         "--style", "compact", "--predicate", logPredicate]
    }

    // MARK: - 採取

    /// 1回の採取。書いたパスを返す(重複・書けないときは nil)。
    /// - `directory`: 書き先(`diagnostics/` を含まない親)。nil なら `currentRunDirectory`、それも無ければ `fallbackDirectory`
    /// - launchctl とクラッシュレポートは同期で採り(速い)、統合ログは背景で採ってファイルを書き直す。
    ///   背景が終わる前にプロセスが終わると、ファイルには「log not captured」が残る(黙って欠けない)
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
        let pending = head + "\n== unified log ==\nlog not captured (process exited before `log show` finished)\n"
        guard (try? pending.write(to: url, atomically: true, encoding: .utf8)) != nil else {
            release()
            log("Simulator diagnostics not saved: could not write \(url.path)")
            return nil
        }
        log("Simulator diagnostics saved: \(url.path) (the unified log is still being collected in the background)")

        let command = logShowCommand(udid: udid)
        let work: @Sendable () -> Void = {
            let section = logSection(command: command, commands: commands)
            try? (head + "\n== unified log ==\n" + section).write(to: url, atomically: true, encoding: .utf8)
            completion?()
        }
        let thread = Thread { work() }
        thread.name = "fleetest-simulator-diagnostics"
        thread.start()
        return url
    }

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
            let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let tail = lines.suffix(logTailLines)
            let header = "last \(logLookbackMinutes)m, predicate: \(logPredicate)\n"
                + "showing the last \(tail.count) of \(lines.count) lines\n"
            return header + tail.joined(separator: "\n") + "\n"
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

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.string(from: date)
    }

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
