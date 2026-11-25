// シミュレータの SpringBoard が外観の変更をアプリへ届けられる状態かを、XCUITest ランナーを起こす前に1回確かめる。
// 届けられない SpringBoard は、外観の部品(`UserInterfaceStyleArbiter`)が起動の瞬間の1回だけ動いて以後1度も変更を受けない
// (起動から数時間そのまま = run の中の `display-not-applied` の検出と回復が毎回払っていた)。起動し直せば直る
// (15 回中 15 回)。確かめ方: 外観を反対へ1度変えて、部品が「changing style」を記録したかを統合ログで読み、元へ戻す。
// 反応しなければ SpringBoard を起こし直して1回だけ確かめ直す。**ランナーを起こす前だけ撃つ**(起こし直しはランナーとアプリも落とす)。
// 読めない・コマンドが失敗したときは何もしない(言えないことで起動を止めない)

import Foundation

public enum SimulatorAppearanceArbiter {

    /// 外観を変えてから統合ログを読むまでの待ち(秒)。根拠: 届く SpringBoard の部品は要求の 12ms 後に記録した(実測)。
    /// その 80 倍余り。尽きても読み直さない(読めなければ「反応なし」として1回だけ起こし直す)
    static let reactionWaitSeconds: Double = 1

    /// `xcrun simctl ui <udid> appearance` の答えを読む。light / dark 以外は nil
    public static func parseAppearance(_ output: String) -> String? {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "light" || value == "dark" ? value : nil
    }

    /// 統合ログの出力に、部品が外観を変えた行があるか
    public static func arbiterReacted(_ logOutput: String) -> Bool {
        logOutput.split(separator: "\n").contains {
            $0.contains("UserInterfaceStyleArbiter") && $0.contains("changing style")
        }
    }

    /// 起こし直した SpringBoard の部品が立ち上がった(起動の1回 `forReason:0` を記録した)か
    public static func arbiterStarted(_ logOutput: String) -> Bool {
        logOutput.split(separator: "\n").contains {
            $0.contains("UserInterfaceStyleArbiter") && $0.contains("forReason:0")
        }
    }

    static func logShowCommand(udid: String, since: Date, message: String) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return ["xcrun", "simctl", "spawn", udid, "log", "show", "--start", formatter.string(from: since),
                "--style", "compact", "--predicate",
                "category == \"UserInterfaceStyleArbiter\" AND eventMessage CONTAINS \"\(message)\""]
    }

    /// 起こし直した後、部品の起動の行が出るまで待つ上限(秒)。根拠: 起こし直しの上限(`SimulatorSpringBoard.restartTimeoutSeconds`)と同じ
    static let arbiterStartWaitSeconds = SimulatorSpringBoard.restartTimeoutSeconds

    public enum Verdict: Equatable, Sendable {
        case responsive
        /// 反応しなかったので起こし直し、確かめ直した結果(`responsive` = 直った)
        case restarted(responsiveAfter: Bool)
        /// 確かめられなかった(理由)
        case unchecked(String)
    }

    public typealias CommandRunner = ([String], Double) throws -> Shell.Result

    /// 1回確かめる(反応したか / nil = 確かめられなかった)。外観は必ず元へ戻す
    static func probe(udid: String, run: CommandRunner, now: () -> Date, sleep: (Double) -> Void) -> Bool? {
        guard let current = (try? run(["xcrun", "simctl", "ui", udid, "appearance"], 30))?.outputIfSucceeded
            .flatMap(parseAppearance) else { return nil }
        let other = current == "light" ? "dark" : "light"
        // 秒の切り捨てで読み始める(--start は秒単位)。この前の自分の変更を数えないよう、変える直前の時刻を取る
        let since = now()
        guard (try? run(["xcrun", "simctl", "ui", udid, "appearance", other], 30))?.status == 0 else { return nil }
        sleep(reactionWaitSeconds)
        let output = (try? run(logShowCommand(udid: udid, since: since, message: "changing style"), 60))?.outputIfSucceeded
        _ = try? run(["xcrun", "simctl", "ui", udid, "appearance", current], 30)
        return output.map(arbiterReacted)
    }

    public static func ensureResponsive(udid: String, log: (String) -> Void,
                                        run: CommandRunner = { try Shell.run($0, timeout: $1) },
                                        restart: (String) -> (ok: Bool, detail: String) = SimulatorSpringBoard.restart,
                                        now: () -> Date = Date.init,
                                        sleep: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> Verdict {
        guard let first = probe(udid: udid, run: run, now: now, sleep: sleep) else {
            return .unchecked("the appearance or the unified log could not be read")
        }
        if first { return .responsive }
        log("SpringBoard did not apply an appearance change (its appearance arbiter stayed silent); restarting SpringBoard"
            + " before starting the runner, as apps on this simulator would not receive display settings")
        let restartedAt = now()
        let restarted = restart(udid)
        guard restarted.ok else { return .unchecked("restarting SpringBoard failed: \(restarted.detail)") }
        // 部品が立ち上がるまで待つ(立ち上がる前に確かめると「反応なし」と読む)。1回の読みは約2秒
        let deadline = restartedAt.addingTimeInterval(arbiterStartWaitSeconds)
        while now() < deadline {
            let started = (try? run(logShowCommand(udid: udid, since: restartedAt, message: "forReason:0"), 60))?
                .outputIfSucceeded.map(arbiterStarted) ?? false
            if started { break }
            sleep(reactionWaitSeconds)
        }
        let after = probe(udid: udid, run: run, now: now, sleep: sleep) ?? false
        if !after {
            log("SpringBoard still did not apply an appearance change after the restart; scenarios that change the"
                + " appearance may fail with display-not-applied on this simulator")
        }
        return .restarted(responsiveAfter: after)
    }
}
