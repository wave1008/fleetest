// シミュレータの SpringBoard が外観の変更をアプリへ届けられる状態かを、XCUITest ランナーを起こす前に1回確かめる。
// 届けられない SpringBoard は、外観の部品(`UserInterfaceStyleArbiter`)が起動の瞬間の1回(`forReason:0`)だけ動いて以後1度も
// 変更を受けない(起動から数時間そのまま = run の中の `display-not-applied` の検出と回復が毎回払っていた)。起こし直せば直る(15 回中 15 回)。
// 確かめ方: ①今の SpringBoard(pid)の部品の起動の行を統合ログで見つける(起こし直した直後なら立ち上がるまで待つ。見つからなければ
// 確かめない = OS の更新でログの文言が変わっても、反応なしと読んで起こし直さない)②外観を反対へ1度変えて元へ戻し、その pid の部品が
// 「changing style」を記録したかを読む。記録しなければ、呼び手が許すときだけ SpringBoard を起こし直して1回だけ確かめ直す。
// **起こし直しはランナーとアプリも落とす**ので、呼び手はランナーを起こす前・同じ台のブリッジを使い回さないときだけ許す。
// 外観を変える子(`simctl ui`)は1秒で元へ戻し、ログはその後で読む(戻した後も記録は読める)。中断で戻す前に止まっても、各シナリオの
// 開始が表示条件を合わせ直す(中断のリレーに載せない理由。.claude/rules/process-lifecycle.md の例外の表)

import Foundation

public enum SimulatorAppearanceArbiter {

    /// 外観を変えてから戻すまでの待ち(秒)。根拠: 届く SpringBoard の部品は要求の 12ms 後に記録した(実測)。その 80 倍余り
    static let reactionWaitSeconds: Double = 1

    /// 部品の起動の行が出るまで待つ上限(秒)。根拠: SpringBoard の起こし直しの上限(`SimulatorSpringBoard.restartTimeoutSeconds`)と
    /// 同じ = 起こし直した直後の確かめでも立ち上がりを待てる。尽きたら確かめない(`.unchecked`。反応なしとは読まない)
    static let arbiterStartWaitSeconds: Double = 30

    /// 起動の行を探す窓(時間)。これより前に起動した SpringBoard は起動の行が窓の外 = 確かめない(言えないことで起こし直さない)
    static let startLookbackHours = 24

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

    /// 部品が立ち上がった(起動の1回 `forReason:0` を記録した)か
    public static func arbiterStarted(_ logOutput: String) -> Bool {
        logOutput.split(separator: "\n").contains {
            $0.contains("UserInterfaceStyleArbiter") && $0.contains("forReason:0")
        }
    }

    /// `launchctl list` の出力から SpringBoard の pid
    public static func springBoardPID(_ launchctlOutput: String) -> Int? {
        for line in launchctlOutput.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            if fields.count >= 3, fields[2] == "com.apple.SpringBoard" { return Int(fields[0]) }
        }
        return nil
    }

    static func predicate(pid: Int, message: String) -> String {
        "processID == \(pid) AND category == \"UserInterfaceStyleArbiter\" AND eventMessage CONTAINS \"\(message)\""
    }

    static func logShowCommand(udid: String, since: Date, pid: Int, message: String) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return ["xcrun", "simctl", "spawn", udid, "log", "show", "--start", formatter.string(from: since),
                "--style", "compact", "--predicate", predicate(pid: pid, message: message)]
    }

    static func startLogCommand(udid: String, pid: Int) -> [String] {
        ["xcrun", "simctl", "spawn", udid, "log", "show", "--last", "\(startLookbackHours)h",
         "--style", "compact", "--predicate", predicate(pid: pid, message: "forReason:0")]
    }

    public enum Verdict: Equatable, Sendable {
        case responsive
        /// 反応しなかったので起こし直し、確かめ直した結果(`responsive` = 直った)
        case restarted(responsiveAfter: Bool)
        /// 反応しなかったが、呼び手が起こし直しを許さなかった(同じ台のブリッジを使い回しうる)
        case unresponsiveNotRestarted
        /// 確かめられなかった(理由)
        case unchecked(String)
    }

    public typealias CommandRunner = ([String], Double) throws -> Shell.Result

    /// 今の SpringBoard の pid と、その部品の起動の行が見えるまで待つ。見えなければ nil(理由)
    static func liveArbiter(udid: String, run: CommandRunner, now: () -> Date,
                            sleep: (Double) -> Void) -> Result<Int, ArbiterUnseen> {
        let deadline = now().addingTimeInterval(arbiterStartWaitSeconds)
        while true {
            if let pid = (try? run(["xcrun", "simctl", "spawn", udid, "launchctl", "list"], 30))?
                .outputIfSucceeded.flatMap(springBoardPID),
               let output = (try? run(startLogCommand(udid: udid, pid: pid), 60))?.outputIfSucceeded,
               arbiterStarted(output) {
                return .success(pid)
            }
            guard now() < deadline else { return .failure(ArbiterUnseen()) }
            sleep(reactionWaitSeconds)
        }
    }

    struct ArbiterUnseen: Error {}

    /// 1回確かめる(反応したか / nil = 確かめられなかった)。外観は必ず元へ戻し、ログは戻した後で読む
    static func probe(udid: String, pid: Int, run: CommandRunner, now: () -> Date, sleep: (Double) -> Void) -> Bool? {
        guard let current = (try? run(["xcrun", "simctl", "ui", udid, "appearance"], 30))?.outputIfSucceeded
            .flatMap(parseAppearance) else { return nil }
        let other = current == "light" ? "dark" : "light"
        let since = now()   // --start は秒単位。変える直前の時刻から読む
        guard (try? run(["xcrun", "simctl", "ui", udid, "appearance", other], 30))?.status == 0 else { return nil }
        sleep(reactionWaitSeconds)
        _ = try? run(["xcrun", "simctl", "ui", udid, "appearance", current], 30)
        return (try? run(logShowCommand(udid: udid, since: since, pid: pid, message: "changing style"), 60))?
            .outputIfSucceeded.map(arbiterReacted)
    }

    public static func ensureResponsive(udid: String, restartAllowed: Bool, log: (String) -> Void,
                                        run: CommandRunner = { try Shell.run($0, timeout: $1) },
                                        restart: (String) -> (ok: Bool, detail: String) = SimulatorSpringBoard.restart,
                                        now: () -> Date = Date.init,
                                        sleep: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> Verdict {
        let unseen = "SpringBoard's appearance arbiter was not seen starting in the unified log"
            + " within \(Int(arbiterStartWaitSeconds))s (or SpringBoard started over \(startLookbackHours)h ago)"
        guard case .success(let pid) = liveArbiter(udid: udid, run: run, now: now, sleep: sleep) else {
            return .unchecked(unseen)
        }
        guard let first = probe(udid: udid, pid: pid, run: run, now: now, sleep: sleep) else {
            return .unchecked("the appearance or the unified log could not be read")
        }
        if first { return .responsive }
        guard restartAllowed else {
            log("SpringBoard did not apply an appearance change (its appearance arbiter stayed silent); not restarting it"
                + " because a bridge on this simulator may be reused — scenarios that change the appearance may fail with"
                + " display-not-applied and be recovered then")
            return .unresponsiveNotRestarted
        }
        log("SpringBoard did not apply an appearance change (its appearance arbiter stayed silent); restarting SpringBoard"
            + " before starting the runner, as apps on this simulator would not receive display settings")
        let restarted = restart(udid)
        guard restarted.ok else { return .unchecked("restarting SpringBoard failed: \(restarted.detail)") }
        guard case .success(let newPID) = liveArbiter(udid: udid, run: run, now: now, sleep: sleep) else {
            return .unchecked("after restarting SpringBoard: " + unseen)
        }
        let after = probe(udid: udid, pid: newPID, run: run, now: now, sleep: sleep) ?? false
        if !after {
            log("SpringBoard still did not apply an appearance change after the restart; scenarios that change the"
                + " appearance may fail with display-not-applied on this simulator")
        }
        return .restarted(responsiveAfter: after)
    }
}
