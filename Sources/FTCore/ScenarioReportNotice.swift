// 子が書き終えたシナリオのレポート(.md)へ、親だけが知っている事実を追記する。
// 書式の相手: FTDSL の ScenarioReportWriter(`- Timestamp:` の行の直後に `> ⚠️ ...` の注記を並べる)

import Foundation

public enum ScenarioReportNotice {
    /// 結果を捨てたことをレポートに残す。`- Result:` は書き換えない(子の実行が記録した事実)。読めなければ何もしない
    static func addDiscarded(reason: String, to report: URL) {
        guard let text = try? String(contentsOf: report, encoding: .utf8) else { return }
        try? withDiscardedNotice(text, reason: reason).write(to: report, atomically: true, encoding: .utf8)
    }

    static func withDiscardedNotice(_ report: String, reason: String) -> String {
        let notice = "> ⚠️ This result was discarded: \(reason) was found when the scenario ended, so checks that passed"
            + " may not have looked at the screen. The scenario was handed back to the run; see the re-run's report."
        var lines = report.components(separatedBy: "\n")
        guard let timestamp = lines.firstIndex(where: { $0.hasPrefix("- Timestamp:") }) else { return report }
        lines.insert(contentsOf: ["", notice], at: timestamp + 1)
        return lines.joined(separator: "\n")
    }
}
