// iOS Simulator の PosterBoard(壁紙の管理プロセス)が短時間に落ち続けている台の検出(DS-12.4.5。DR-217)。
// 壊れた台は PosterBoard が落ちるたびに launchd_sim が起こし直し、壁紙の拡張(*Poster*.appex)が一斉に
// 起動し直して数コアを使い続け、同じ Mac の Android Emulator を白紙・固まりに巻き込む(観測: load average 38)。
//
// 入力はホスト Mac のクラッシュ記録 ~/Library/Logs/DiagnosticReports/PosterBoard-*.ips。
// 1行目 = ヘッダ JSON("timestamp" = `timestampFormat` の形)、2行目以降 = 本体 JSON。
// 本体の coalitionName が "com.apple.CoreSimulator.SimDevice.<UDID>"(= どの Simulator か)。
// 判定(`looping`)は純粋関数・読み(`readCrashes`)は I/O。止める側は FTAndroid.PosterBoardCrashLoopGuard。

import Foundation

public struct PosterBoardCrashRecord: Equatable, Sendable {
    public let udid: String
    public let time: Date

    public init(udid: String, time: Date) {
        self.udid = udid
        self.time = time
    }
}

public enum PosterBoardCrashLoop {
    /// 数える窓(秒)。実測(8 日間の全 .ips・`Retired/` を含む・11 台): 健全な 10 台は 10・30・60 分のどの窓でも
    /// 最大 4 回(Duo の 1 台)・ほとんどは 1 回。壊れた台は嵐の日の最大が 10 分の窓で 8〜34 回(8 回の日が 2 日ある = 10 分では
    /// 検出できない日が出る)・30 分の窓で 16〜46 回。記録は落ちた回数より少ない(ReportCrash が間引く。拡張は数秒おきに起動し直していた)
    public static let windowSeconds: TimeInterval = 1800

    /// この回数以上で「落ち続けている」と判定する(回/窓)。30 分の窓で健全な台の最大 4 回の 2.5 倍・壊れた台の嵐の日の最小 16 回より下。
    /// **誤判定したときの害**は「その台を止める」まで(使用中なら止めず警告だけ・消去はしない)。
    /// 窓の外へ古い記録が出れば自然に判定から外れる
    public static let threshold = 10

    /// ヘッダの時刻の書式(年月日・時分秒・百分の一秒・時差。例は DR-217 の調べた .ips)
    static let timestampFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
    static let coalitionPrefix = "com.apple.CoreSimulator.SimDevice."
    static let reportPrefix = "PosterBoard-"
    static let reportSuffix = ".ips"
    static let retiredDirectoryName = "Retired"

    public struct Looping: Equatable, Sendable {
        public let udid: String
        public let count: Int
    }

    /// 直近 `windowSeconds` に `threshold` 回以上落ちた Simulator(UDID ごとに数える)。UDID 昇順
    public static func looping(
        crashes: [PosterBoardCrashRecord], now: Date,
        windowSeconds: TimeInterval = PosterBoardCrashLoop.windowSeconds,
        threshold: Int = PosterBoardCrashLoop.threshold
    ) -> [Looping] {
        let from = now.addingTimeInterval(-windowSeconds)
        var counts: [String: Int] = [:]
        for crash in crashes where crash.time >= from && crash.time <= now {
            counts[crash.udid, default: 0] += 1
        }
        return counts.filter { $0.value >= threshold }
            .map { Looping(udid: $0.key, count: $0.value) }
            .sorted { $0.udid < $1.udid }
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    /// `directory` と その `Retired/` の PosterBoard-*.ips のうち mtime が窓の中のものだけ読む(記録は書かれた時刻が
    /// クラッシュ時刻以降なので、窓の外の mtime は窓の中のクラッシュを持たない)。読めない・形が違う
    /// ファイルは飛ばす。**`Retired/` を落とさない** —— 記録は書かれて間もなく移される(11/22 は 69 件中 23 件が当日のうちに
    /// 移っていた。直下だけ読むと壊れた台の 10:35〜10:45 を当てられなかった)
    public static func readCrashes(
        directory: URL = PosterBoardCrashLoop.defaultDirectory, now: Date = Date(),
        windowSeconds: TimeInterval = PosterBoardCrashLoop.windowSeconds
    ) -> [PosterBoardCrashRecord] {
        let from = now.addingTimeInterval(-windowSeconds)
        let urls = [directory, directory.appendingPathComponent(retiredDirectoryName, isDirectory: true)].flatMap {
            (try? FileManager.default.contentsOfDirectory(
                at: $0, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        }
        var records: [PosterBoardCrashRecord] = []
        for url in urls {
            let name = url.lastPathComponent
            guard name.hasPrefix(reportPrefix), name.hasSuffix(reportSuffix),
                  let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                      .contentModificationDate,
                  modified >= from,
                  let data = try? Data(contentsOf: url),
                  let record = parse(report: data) else { continue }
            records.append(record)
        }
        return records
    }

    /// .ips 1本 → (UDID, 時刻)。ヘッダの timestamp か本体の coalitionName が読めなければ nil
    static func parse(report: Data) -> PosterBoardCrashRecord? {
        guard let newline = report.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        let headerData = report[report.startIndex..<newline]
        let bodyData = report[report.index(after: newline)...]
        guard let header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any],
              let timestamp = header["timestamp"] as? String,
              let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any],
              let coalition = body["coalitionName"] as? String,
              coalition.hasPrefix(coalitionPrefix) else { return nil }
        let udid = String(coalition.dropFirst(coalitionPrefix.count))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = timestampFormat
        guard !udid.isEmpty, let time = formatter.date(from: timestamp) else { return nil }
        return PosterBoardCrashRecord(udid: udid.uppercased(), time: time)
    }
}
