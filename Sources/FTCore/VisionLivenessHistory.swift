// Vision の死活の変わり目の履歴(追記)。台帳(VisionLiveness)は対象ごとの最新1件の上書きなので、
// 「いつ・再起動から何分で OCR / 特徴量が壊れた・戻ったか」を後から突き合わせるためにここへ残す
// (~/.fleetest/vision-history.ndjson。書き方・上限・flock の規律は VideoEncoderHistory と同じ)。
// 1 行 = {"at","boot","uptimeSeconds","subject","event","source","detail"}。

import Foundation

public enum VisionLivenessHistory {
    public enum Event: String, Codable, Sendable {
        /// 台帳がその対象で生から死(または不明から死)へ変わった
        case becameDead
        /// 台帳がその対象で死から生へ変わった
        case becameAlive
    }

    struct Line: Codable, Equatable {
        let at: String
        let boot: String
        let uptimeSeconds: Int
        let subject: VisionLiveness.Subject
        let event: Event
        let source: VisionLiveness.Source
        let detail: String?
    }

    static let fileName = "vision-history.ndjson"
    static let lockFileName = "vision-history.lock"
    /// 上限(バイト)。変わり目だけを書くので VideoEncoderHistory と同じ 5MiB で数年分
    static let maxBytes = 5 * 1024 * 1024

    /// 書き込み先(台帳と同じ門・同じ置き場)。nil = 書かない
    static var writeURL: URL? {
        VisionLiveness.writeURL?.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    public static func append(subject: VisionLiveness.Subject, event: Event, source: VisionLiveness.Source, detail: String?) {
        guard let url = writeURL else { return }
        append(subject: subject, event: event, source: source, detail: detail, to: url)
    }

    static func append(subject: VisionLiveness.Subject, event: Event, source: VisionLiveness.Source, detail: String?,
                       to url: URL, now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let line = Line(at: ISO8601Millis.string(from: now), boot: FMLiveness.Stamp.bootID,
                        uptimeSeconds: Int(uptime.rounded()), subject: subject, event: event, source: source,
                        detail: detail.map { String($0.prefix(VisionLiveness.errorLimit)) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(line) else { return }
        data.append(0x0A)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lock = open(dir.appendingPathComponent(lockFileName).path, O_CREAT | O_NOFOLLOW | O_RDWR, 0o644)
        guard lock >= 0 else { return }
        defer { close(lock) }  // close が flock も解放する
        while flock(lock, LOCK_EX) != 0 {
            if errno != EINTR { return }
        }
        let fd = open(url.path, O_CREAT | O_NOFOLLOW | O_WRONLY | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var info = stat()
        let size = fstat(fd, &info) == 0 ? Int(info.st_size) : 0
        close(fd)
        if written > 0, size > maxBytes { trim(url) }
    }

    /// 新しい側の半分(行単位)を残す。**呼ぶのは append の flock の内側だけ**
    static func trim(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let keepFrom = data.count - maxBytes / 2
        guard keepFrom > 0, let newline = data[keepFrom...].firstIndex(of: 0x0A) else { return }
        try? data[(newline + 1)...].write(to: url, options: .atomic)
    }

    static func read(at url: URL) -> [Line] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(Line.self, from: Data($0.utf8)) }
    }
}
