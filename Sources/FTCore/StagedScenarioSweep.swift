import Foundation

/// `fleetest run-file` が scenarios/_runfile/ へ一時的に置く .swift の残骸の掃除。
/// SIGKILL された run-file は後始末(defer)を走らせられず、残骸は SPM ターゲットに混ざって通常の run にも走る。
/// **持ち主の pid を `.owner` に書き、持ち主が死んでいるときだけ消す**(生きている run-file の置き場を
/// 別の run の開始が消さない。SPM は隠しファイルを無視するのでビルドに影響しない)。
public enum StagedScenarioSweep {
    public static let dirName = "_runfile"
    static let ownerFileName = ".owner"

    public static func stageDirectory(scenariosDir: URL) -> URL {
        scenariosDir.appendingPathComponent(dirName)
    }

    /// 置き場を作った直後に呼ぶ(持ち主 = このプロセス)
    public static func claim(stageDir: URL, pid: pid_t = getpid()) throws {
        try "\(pid)".write(to: stageDir.appendingPathComponent(ownerFileName), atomically: true, encoding: .utf8)
    }

    /// 持ち主が居ない・死んでいる置き場を消す。消したら true。持ち主を読めない置き場(旧形式の残骸を含む)は消す
    @discardableResult
    public static func sweepIfAbandoned(scenariosDir: URL,
                                        isAlive: (pid_t) -> Bool = ProcessLiveness.isAlive) -> Bool {
        let dir = stageDirectory(scenariosDir: scenariosDir)
        guard FileManager.default.fileExists(atPath: dir.path) else { return false }
        if let owner = ownerPID(stageDir: dir), isAlive(owner) { return false }
        return (try? FileManager.default.removeItem(at: dir)) != nil
    }

    static func ownerPID(stageDir: URL) -> pid_t? {
        guard let text = try? String(contentsOf: stageDir.appendingPathComponent(ownerFileName), encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
