// iOS シミュレータのクラッシュレポート(.ips)要約。ホスト Mac が
// ~/Library/Logs/DiagnosticReports に書く。行1=ヘッダ JSON(bundleID 等)、
// 行2以降=ペイロード JSON(exception/termination)。新macOSの JSON形式を優先し、
// 解釈できなければ旧テキスト形式(Identifier:/Exception Type: 等の行)にフォールバックする。

import Foundation

public enum SimulatorCrashReport {
    /// header/payload どちらかが JSON として解釈できなければ nil(例外は投げない)。
    public static func summarize(headerLine: String, payload: String) -> (bundleID: String?, reason: String?)? {
        guard let headerData = headerLine.data(using: .utf8),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any] else {
            return nil
        }
        guard let payloadData = payload.data(using: .utf8),
              let body = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }
        let bundleID = header["bundleID"] as? String
        return (bundleID, extractReason(from: body))
    }

    private static func extractReason(from body: [String: Any]) -> String? {
        var parts: [String] = []
        if let exception = body["exception"] as? [String: Any] {
            let fields = [exception["type"] as? String, exception["signal"] as? String].compactMap { $0 }
            if !fields.isEmpty { parts.append(fields.joined(separator: " ")) }
        }
        // dyld 由来の即死は exception が EXC_CRASH SIGABRT にしかならず、**何が読めなかったのか**は
        // termination.reasons にしか出ない(実害: シミュレータのランタイム共有キャッシュ破損で
        // "Library not loaded: libSystem.B.dylib / no dyld cache"。受け手報告)
        if let dyld = dyldDetail(from: body) { parts.append(dyld) }
        if parts.isEmpty, let termination = body["termination"] as? [String: Any] {
            let name = termination["name"] as? String ?? (termination["signal"] as? Int).map { "signal \($0)" }
            let fields = [termination["indicator"] as? String, name].compactMap { $0 }
            if !fields.isEmpty { parts.append(fields.joined(separator: " ")) }
        }
        return parts.isEmpty ? nil : oneLine(parts.joined(separator: " / "))
    }

    /// termination が DYLD 名前空間か reasons を持つときだけ返す(通常のクラッシュでは nil =
    /// 既存の文言を変えない)。reasons は「読めなかった dylib」と「なぜ」が別の行に来るので2行まで
    private static func dyldDetail(from body: [String: Any]) -> String? {
        guard let termination = body["termination"] as? [String: Any] else { return nil }
        let namespace = termination["namespace"] as? String
        let reasons = (termination["reasons"] as? [String])?.filter { !$0.isEmpty } ?? []
        guard namespace == "DYLD" || !reasons.isEmpty else { return nil }
        let head = [namespace, termination["indicator"] as? String]
            .compactMap { $0 }.joined(separator: " ")
        let detail = reasons.prefix(2).joined(separator: "; ")
        return [head, detail].filter { !$0.isEmpty }.joined(separator: ": ")
    }

    private static func oneLine(_ s: String) -> String? {
        let flattened = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.isEmpty ? nil : flattened
    }

    /// 旧テキスト形式 .ips 用フォールバック。「ラベル: 値」の行を素朴に走査する(正規表現不要)。
    public static func summarizeTextFormat(_ text: String) -> (bundleID: String?, reason: String?)? {
        var bundleID: String?
        var exceptionType: String?
        var terminationReason: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if bundleID == nil {
                bundleID = value(afterPrefix: "Identifier:", in: s)
            }
            if exceptionType == nil {
                exceptionType = value(afterPrefix: "Exception Type:", in: s)
            }
            if terminationReason == nil {
                terminationReason = value(afterPrefix: "Termination Reason:", in: s)
            }
        }
        let reasonParts = [exceptionType, terminationReason].compactMap { $0 }
        let reason = reasonParts.isEmpty ? nil : oneLine(reasonParts.joined(separator: " / "))
        guard bundleID != nil || reason != nil else { return nil }
        return (bundleID, reason)
    }

    private static func value(afterPrefix prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let v = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    /// レポートを書いたシミュレータの UDID。本体の `coalitionName`(`com.apple.CoreSimulator.SimDevice.<UDID>`)を
    /// 先に、無ければ `procPath`(`…/CoreSimulator/Devices/<UDID>/…`)から取る。JSON は `/` を `\/` と書くので
    /// 素のテキストへ当てる(旧テキスト形式の Coalition:/Path: 行にも同じ形で当たる)。読めなければ nil
    public static func deviceUDID(inReport content: String) -> String? {
        let patterns = [#"SimDevice\.([0-9A-Fa-f-]{36})"#, #"CoreSimulator\\?/Devices\\?/([0-9A-Fa-f-]{36})"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
                  let range = Range(match.range(at: 1), in: content) else { continue }
            return String(content[range]).uppercased()
        }
        return nil
    }

    /// dir 内の直近クラッシュを新しい順に探し、bundleID が一致する最初の1件を返す。
    /// `udid`: 非 nil なら**そのシミュレータのレポートだけ**(同じアプリを並行で回すと別デバイスの .ips が
    /// 同じ窓に入る)。デバイスを読めないレポートは帰属させない。nil はデバイスで絞らない。
    /// **既定値は付けない**(run の経路の渡し忘れをコンパイルで止める)
    public static func findRecent(
        bundleID: String,
        udid: String?,
        within seconds: TimeInterval = 120,
        dir: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports"),
        now: Date = Date()
    ) -> (path: String, reason: String?)? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return nil }

        let cutoff = now.addingTimeInterval(-seconds)
        let candidates = entries
            .filter { $0.pathExtension == "ips" }
            .compactMap { url -> (URL, Date)? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let mtime = values.contentModificationDate, mtime >= cutoff else { return nil }
                return (url, mtime)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(50) // DiagnosticReports が肥大化していても走査を打ち切るための上限

        for (url, _) in candidates {
            guard let content = readWholeText(url) else { continue }
            // JSON 形式を優先(既存の header/payload 分割 + summarize)。summarize が nil なら
            // 旧テキスト形式にフォールバック。JSON ファイルは分割が失敗しないため既存挙動は不変。
            let summary = splitHeaderAndPayload(content)
                .flatMap { summarize(headerLine: $0.header, payload: $0.payload) }
                ?? summarizeTextFormat(content)
            guard let summary, summary.bundleID == bundleID else { continue }
            // **ファイルの mtime は証拠にならない**: 同じアプリの .ips が macOS の保持上限に達すると、
            // 以後のクラッシュは新しいファイルを作らず最古の1件の mtime だけを進める。中身が書く
            // 時刻(captureTime)で窓に入るかを確かめ、古い別プロセスの報告を指さない。
            // 時刻を読めない形(旧テキスト形式・タイムゾーン無し)は mtime のまま
            if let captured = reportTime(inReport: content), captured < cutoff { continue }
            if let udid, deviceUDID(inReport: content) != udid.uppercased() { continue }
            return (url.path, summary.reason)
        }
        return nil
    }

    /// **mtime だけが窓に入り、中身(captureTime)は窓より古い**同じアプリの報告のパス。`findRecent` が捨てる形:
    /// 同じアプリの .ips が保持上限に達すると、以後のクラッシュは新しいファイルを作らず最古の1件の mtime だけを進める。
    /// これは「新しい報告」ではない(中身は前のクラッシュ)ので**このクラッシュの報告として指さない**。
    /// 呼び手はアプリの死を別途観測したときだけ「報告が上書きされた可能性」の証拠にする(mtime だけでは他の更新と区別できない)
    public static func findRewrittenInPlace(
        bundleID: String,
        within seconds: TimeInterval,
        dir: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports"),
        now: Date = Date()
    ) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        let cutoff = now.addingTimeInterval(-seconds)
        let candidates = entries
            .filter { $0.pathExtension == "ips" }
            .compactMap { url -> (URL, Date)? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let mtime = values.contentModificationDate, mtime >= cutoff else { return nil }
                return (url, mtime)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(50)
        for (url, _) in candidates {
            guard let content = readWholeText(url) else { continue }
            let summary = splitHeaderAndPayload(content)
                .flatMap { summarize(headerLine: $0.header, payload: $0.payload) }
                ?? summarizeTextFormat(content)
            guard let summary, summary.bundleID == bundleID,
                  let captured = reportTime(inReport: content), captured < cutoff else { continue }
            return url.path
        }
        return nil
    }

    /// レポートが書く発生時刻(ペイロードの `captureTime`、無ければヘッダの `timestamp`)。
    /// 「YYYY-MM-DD hh:mm:ss.ffff +0900」の形でタイムゾーンを持つものだけ読む。読めなければ nil
    public static func reportTime(inReport content: String) -> Date? {
        for key in ["captureTime", "timestamp"] {
            let pattern = "\"\(key)\"\\s*:\\s*\"(\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2})(?:\\.\\d+)? ([+-]\\d{4})\""
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
                  let local = Range(match.range(at: 1), in: content),
                  let zone = Range(match.range(at: 2), in: content) else { continue }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            if let date = formatter.date(from: "\(content[local]) \(content[zone])") { return date }
        }
        return nil
    }

    /// 落ちると、起き直すまでの間ステップが見る画面そのものが欠けるシステムのプロセス(`file` = .ips のファイル名の頭 = app_name)。
    /// SpringBoard: アプリが背景に回る(in-app ブリッジは 423)/ InputUI: キーボードが消える(hideKeyboard が「出ていない」で ✅)。
    /// iPhone Duo の開閉の後に FBSDisplayMode の assert で約 18 秒おきに落ち続ける。観測したこの2つだけ
    public static let screenSystemProcesses: [(file: String, bundleID: String, role: String)] = [
        ("SpringBoard", "com.apple.springboard", "the app goes to the background while it restarts"),
        ("InputUI", "com.apple.InputUI", "no keyboard is on screen while it restarts"),
    ]

    public struct SystemCrash: Equatable, Sendable {
        public let name: String
        public let time: Date
        public let path: String
    }

    /// `since` 以降にこのシミュレータで落ちた `screenSystemProcesses` の報告(古い順)。ファイル名の頭で先に絞る
    /// (落ち続けると他のデーモンの報告も同じ窓に並ぶので、findRecent の 50 件の上限に掛けない)。
    /// 発生時刻(`reportTime`)を読めない・デバイスを読めない報告は帰属させない
    public static func systemCrashes(udid: String, since: Date,
                                     dir: URL = FileManager.default.homeDirectoryForCurrentUser
                                         .appendingPathComponent("Library/Logs/DiagnosticReports")) -> [SystemCrash] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var found: [SystemCrash] = []
        for process in screenSystemProcesses {
            for name in names where name.hasPrefix(process.file + "-") && name.hasSuffix(".ips") {
                let url = dir.appendingPathComponent(name)
                guard let content = readWholeText(url),
                      let header = splitHeaderAndPayload(content)?.header,
                      header.contains("\"bundleID\":\"\(process.bundleID)\""),
                      deviceUDID(inReport: content) == udid.uppercased(),
                      let time = reportTime(inReport: content), time >= since else { continue }
                found.append(SystemCrash(name: process.file, time: time, path: url.path))
            }
        }
        return found.sorted { $0.time < $1.time }
    }

    /// シナリオの報告に添える1行(事実だけ: 何が何回・最初と最後の時刻・役割・報告1件)。無ければ nil
    public static func systemCrashNotice(_ crashes: [SystemCrash], timeZone: TimeZone = .current) -> String? {
        guard let first = crashes.first, let last = crashes.last else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        let counts = screenSystemProcesses.compactMap { process -> String? in
            let n = crashes.filter { $0.name == process.file }.count
            return n == 0 ? nil : "\(process.file) \(n) time\(n == 1 ? "" : "s") (\(process.role))"
        }
        let span = crashes.count == 1 ? "at \(formatter.string(from: first.time))"
            : "from \(formatter.string(from: first.time)) to \(formatter.string(from: last.time))"
        return "the simulator's system processes crashed while this scenario ran: " + counts.joined(separator: ", ")
            + ", \(span); a step reported ok in that span may have run while one of them was restarting (latest report: \(last.path))"
    }

    private static func readWholeText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func splitHeaderAndPayload(_ content: String) -> (header: String, payload: String)? {
        guard let newline = content.firstIndex(of: "\n") else { return nil }
        return (String(content[content.startIndex..<newline]), String(content[content.index(after: newline)...]))
    }
}
