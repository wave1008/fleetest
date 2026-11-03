// DispatchSelfCopy.swift
// リモートへの単一ディスパッチの中継役を、`.build` の実行ファイルではなく一時ディレクトリのコピーから動かす。
// 手元で `swift build` すると `.build` の fleetest が上書きされ、走っている中継役が SIGKILL される(MN-4.1)。
// この経路が手元の `.build` から使うのは fleetest 本体だけ(シナリオのビルド・ヘルパー・services・FM は
// ランナー側で動く。中継役が起こすのは ssh / rsync / git だけ)なので、本体をコピーへ移せば、
// リモートで回している間も手元でビルドして単体テストを回せる。
//
// 守ること:
// - **`--work-queue` の子では呼ばない** —— 入口で stdin を close-on-exec の fd へ移している(WorkQueueStdin)ので、
//   exec すると親からの返事の通り道が消える。その子を起こすのは複数機械の run の親で、親は手元でビルドする = 対象外
// - **手元のデバイスを含む run では呼ばない**(手元のシナリオ実行バイナリとヘルパーを使う。呼び手は単一の
//   リモートへの分岐の中だけで呼ぶ = `ToolSyncForwardingTests` と同じ形の走査で固定)
// - 置き場は `<tmp>/fleetest-dispatch-<pid>`。exec は pid を変えないので終わったら自分で消し、シグナルで死んだ
//   残りは次の呼び出しが pid の生死で掃く
// - コピーは clonefile(APFS の複製 = 中身を写さないので 100MB 超でも即座・元を書き換えても影響しない)。
//   できなければ普通のコピー。失敗・exec の失敗は1行言って `.build` のまま続ける(この最適化の失敗で run を止めない)

import Darwin
import FTCore
import Foundation

enum DispatchSelfCopy {
    /// コピーで動いている印(値 = 置き場)。2回目の呼び出しは exec せず、終了時の後始末だけを登録する
    static let environmentKey = "FT_DISPATCH_SELF_COPY"
    static let directoryPrefix = "fleetest-dispatch-"

    static func reexecIfNeeded(log: (String) -> Void) {
        if ProcessInfo.processInfo.environment[environmentKey] != nil {
            atexit {
                if let dir = getenv(DispatchSelfCopy.environmentKey) {
                    try? FileManager.default.removeItem(atPath: String(cString: dir))
                }
            }
            return
        }
        guard let executable = ExecutablePath.current, isUnderBuildDirectory(executable.path) else { return }
        let base = FileManager.default.temporaryDirectory
        sweepAbandoned(in: base)
        let dir = base.appendingPathComponent(directoryPrefix + String(getpid()))
        let copy = dir.appendingPathComponent(executable.lastPathComponent)
        do {
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if clonefile(executable.path, copy.path, 0) != 0 {
                try FileManager.default.copyItem(at: executable, to: copy)
            }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            log("warning: could not copy fleetest for the relay (\(error.localizedDescription)); relaying from"
                + " \(executable.path) — rebuilding this clone during the run would kill it")
            return
        }
        setenv(environmentKey, dir.path, 1)
        execv(copy.path, CommandLine.unsafeArgv)
        // ここに来たら exec の失敗
        let reason = String(cString: strerror(errno))
        unsetenv(environmentKey)
        try? FileManager.default.removeItem(at: dir)
        log("warning: could not relay from a copy of fleetest (\(reason)); relaying from \(executable.path)"
            + " — rebuilding this clone during the run would kill it")
    }

    /// SwiftPM のビルド成果物の置き場(`.build/...`)から動いているか。それ以外(PATH に置いた fleetest 等)は
    /// ビルドで差し替わらないのでコピーしない
    static func isUnderBuildDirectory(_ path: String) -> Bool {
        path.contains("/.build/")
    }

    /// `fleetest-dispatch-<pid>` の pid。形が違えば nil(掃除しない)
    static func ownerPID(ofDirectoryNamed name: String) -> pid_t? {
        guard name.hasPrefix(directoryPrefix) else { return nil }
        return pid_t(name.dropFirst(directoryPrefix.count))
    }

    /// 持ち主の pid が死んでいる置き場を消す(シグナルで死んだ中継役の残り)
    static func sweepAbandoned(in base: URL, isAlive: (pid_t) -> Bool = ProcessLiveness.isAlive) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return }
        for name in names {
            guard let pid = ownerPID(ofDirectoryNamed: name), pid != getpid(), !isAlive(pid) else { continue }
            try? FileManager.default.removeItem(at: base.appendingPathComponent(name))
        }
    }
}
