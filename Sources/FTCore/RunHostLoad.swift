// run 1件ぶんのホスト負荷(results/runs/<YYYY-MM>/<runID>/host-metrics.ndjson と、ローテ済みの古い世代 .1)の
// 集計。results-compare が比べる2つの run の横に出す数字で、解釈(原因の分類)は付けない(DR-1)。
// 行の形の契約は HostMetricsSampler.swift 冒頭。

import Foundation

/// cpu/gpu は 0〜1 の比(HostMetricsSample のまま。百分率にしない)。
/// 省略可能な欄は JSON 上で null を明示する(自動合成の Encodable はキーごと省くので手書き encode(to:))。
public struct RunHostLoadStat: Equatable, Sendable {
    public let median: Double?
    public let peak: Double?
}

extension RunHostLoadStat: Encodable {
    private enum CodingKeys: String, CodingKey { case median, peak }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(median, forKey: .median)
        try c.encode(peak, forKey: .peak)
    }
}

public struct RunHostLoad: Equatable, Sendable {
    public let runID: String
    /// run メタの host。メタを読めなかったときだけ nil
    public let machine: String?
    /// 0 = その run はホスト負荷を記録していない(事実。エラーではない)
    public let samples: Int
    public let cpu: RunHostLoadStat
    public let gpu: RunHostLoadStat
    public let memPeakUsedBytes: Int?
    public let memTotalBytes: Int?

    /// 古い世代(.1)→現行の順に読んだ行から集計する。ファイルが無ければ samples 0・欄は nil。
    public static func load(runDir: URL, runID: String) -> RunHostLoad {
        let base = runDir.appendingPathComponent("host-metrics.ndjson").path
        var lines: [String] = []
        for path in [base + ".1", base] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            lines += String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
        return summarize(lines: lines, runID: runID, machine: RunResultsStore.meta(runDir: runDir)?.host)
    }

    /// `kind:"hostMetrics"` で `ts` を持つ行だけを数える。偶数個の中央値は中央2値の平均。メモリ総量は最後に見た値。
    public static func summarize(lines: [String], runID: String, machine: String?) -> RunHostLoad {
        var cpu: [Double] = [], gpu: [Double] = [], memUsed: [Int] = []
        var memTotal: Int?
        var samples = 0
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["kind"] as? String == "hostMetrics",
                  obj["ts"] as? Double != nil else { continue }
            samples += 1
            if let v = obj["cpu"] as? Double { cpu.append(v) }
            if let v = obj["gpu"] as? Double { gpu.append(v) }
            if let v = obj["memUsedBytes"] as? Int { memUsed.append(v) }
            if let v = obj["memTotalBytes"] as? Int { memTotal = v }
        }
        return RunHostLoad(runID: runID, machine: machine, samples: samples,
                           cpu: stat(cpu), gpu: stat(gpu),
                           memPeakUsedBytes: memUsed.max(), memTotalBytes: memTotal)
    }

    static func stat(_ values: [Double]) -> RunHostLoadStat {
        guard !values.isEmpty else { return RunHostLoadStat(median: nil, peak: nil) }
        let s = values.sorted()
        let mid = s.count / 2
        let median = s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
        return RunHostLoadStat(median: median, peak: s.last)
    }
}

extension RunHostLoad: Encodable {
    private enum CodingKeys: String, CodingKey {
        case runID, machine, samples, cpu, gpu, memPeakUsedBytes, memTotalBytes
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(runID, forKey: .runID)
        try c.encode(machine, forKey: .machine)
        try c.encode(samples, forKey: .samples)
        try c.encode(cpu, forKey: .cpu)
        try c.encode(gpu, forKey: .gpu)
        try c.encode(memPeakUsedBytes, forKey: .memPeakUsedBytes)
        try c.encode(memTotalBytes, forKey: .memTotalBytes)
    }
}
