// RemoteAlign.swift
// `remote align` / `remote setup` の align 段 / `run --align` が**共有する**ランナーへの直送・ビルドの I/O
// (経路を複製しない)。純粋部分は Sources/FTRemote/RemoteAlignPlan.swift・AlignSnapshot.swift。
// 呼び手: RemoteSetupCommand.swift(`remote align` は `RemoteAlign.execute`・`remote setup` は個々の関数)・
// Fleetest.swift / ApiRunCommand.swift の `--align`(`RemoteAlign.execute(guarded: true)`)。

import ArgumentParser
import FTBridgeClient
import FTCore
import FTRemote
import Foundation

let setupSSHBase = ["ssh"] + SSHOptions.batchConnectArgs + SSHOptions.keepAliveArgs
let setupSCPBase = ["scp"] + SSHOptions.batchConnectArgs + SSHOptions.keepAliveArgs

/// 進行の出力先。**`api run` の stdout は NDJSON 専用**なので、そこから呼ぶときは stderr へ逃がす
/// (子の git push / ssh の出力も `runInheritedSSH(stdoutToStderr:)` で同じ向きへ)。**print は使わない**
/// (stdout が端末でないと libc の行バッファが効かず、分単位かかる進行が最後まで出ない)
struct AlignIO {
    let toStderr: Bool
    static let stdout = AlignIO(toStderr: false)
    static let stderr = AlignIO(toStderr: true)
    func say(_ message: String) {
        if toStderr { ConsoleOut.err(message) } else { ConsoleOut.out(message) }
    }
}

/// ssh/scp をそのまま実行して stdout/stderr を継承する(RemoteRunDispatcher.runInherited と
/// 同じ規律だが private のため複製する)。`stdoutToStderr`: `api run` の NDJSON は stdout 専用なので、揃える出力は stderr へ逃がす。preflight/install/align は数分かかり得るため、
/// 出力をバッファせずその場で流す(受け手側スクリプトの逐次表示をそのまま見せる)
func runInheritedSSH(_ argv: [String], stdoutToStderr: Bool = false) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = argv
    process.standardOutput = stdoutToStderr ? FileHandle.standardError : FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    let waitForExit = ProcessExitWait.prepareBlocking(process)
    try process.run()
    let relay = InterruptRelay.forwarding(to: process)
    defer { relay.stop() }
    waitForExit()
    return process.terminationStatus
}

/// 送る中身(手元で決める)。**`developerDir` は判定とビルドで同じ値を使う**(`alignmentDeveloperDir` の解決は1回だけ)
struct AlignPrepared {
    let repoRoot: URL
    let commit: String
    let digest: String
    /// 向きの判定の手元の基点(作業ツリーなら手元の HEAD・`--tool-rev` ならそのコミット)
    let base: String
    let developerDir: String?
}

/// 送るコミットを決める。`toolRev` が nil なら手元の作業ツリーを1つのコミットにする(`AlignSnapshot`。未コミットの変更・
/// 未追跡のファイルも含む。本物のインデックスもブランチも触らない)。あれば `<toolRev>` のコミットそのものを送る
/// (スナップショットは作らない・要約はそのコミットのツリーから)。**ネットワークより先に解く**(ローカルの失敗を ssh の後に出さない)
func prepareAlignment(hostSpec: RemoteHostSpec, repoRoot: URL, toolRev: String? = nil,
                      io: AlignIO = .stdout) throws -> AlignPrepared {
    if let toolRev {
        let revision: AlignSnapshot.RevisionTree
        do {
            revision = try AlignSnapshot.revisionTree(repoRoot: repoRoot, rev: toolRev)
        } catch {
            throw RemoteDispatchError.remoteSetupFailed(error.localizedDescription)
        }
        try RemoteSetupPlan.validateRevision(revision.commit)
        io.say(RemoteAlignPlan.sendLine(toolRev: toolRev, commit: revision.commit))
        return AlignPrepared(repoRoot: repoRoot, commit: revision.commit, digest: revision.digest,
                             base: revision.commit, developerDir: alignmentDeveloperDir(hostSpec: hostSpec))
    }
    let issuer = try resolveLayoutIssuer()
    let local: AlignSnapshot.LocalTree
    let commit: String
    let untracked: (count: Int, bytes: Int64)
    do {
        local = try AlignSnapshot.localTree(repoRoot: repoRoot)
        commit = try AlignSnapshot.commitToSend(repoRoot: repoRoot, local: local, issuer: issuer)
        untracked = try AlignSnapshot.untrackedSummary(repoRoot: repoRoot)
    } catch {
        throw RemoteDispatchError.remoteSetupFailed("could not snapshot the local working tree: \(error.localizedDescription)")
    }
    try RemoteSetupPlan.validateRevision(commit)
    io.say(RemoteAlignPlan.sendLine(commit: commit, isSnapshot: !local.isClean,
                                    untrackedCount: untracked.count, untrackedBytes: untracked.bytes))
    return AlignPrepared(repoRoot: repoRoot, commit: commit, digest: local.digest, base: local.head,
                         developerDir: alignmentDeveloperDir(hostSpec: hostSpec))
}

/// ランナーの状態を ssh 1往復で読む(`RemoteAlignPlan.probeCommand`)。読めなければ nil。ssh の警告を行に混ぜない(stdout だけ読む)
func alignmentProbe(hostSpec: RemoteHostSpec, layout: RemoteLayout, prepared: AlignPrepared) -> RemoteAlignPlan.ProbeState? {
    guard let result = try? Shell.runData(setupSSHBase + ["-n", hostSpec.sshTarget,
            RemoteAlignPlan.probeCommand(layout: layout, developerDir: prepared.developerDir)]),
          result.status == 0, let text = String(data: result.data, encoding: .utf8) else { return nil }
    return RemoteAlignPlan.parseProbe(text)
}

/// ランナーが送る中身・同じ Xcode でビルド済みか(`RemoteAlignPlan.isAlreadyAligned`)。
/// **読めなかったら false**(揃っていない側へ倒す = 余分にビルドするだけで、古いまま緑にはならない)
func alignmentAlreadyDone(hostSpec: RemoteHostSpec, layout: RemoteLayout, prepared: AlignPrepared) -> Bool {
    guard let state = alignmentProbe(hostSpec: hostSpec, layout: layout, prepared: prepared) else { return false }
    return RemoteAlignPlan.isAlreadyAligned(localDigest: prepared.digest, developerDir: prepared.developerDir,
                                            state: state)
}

/// 送って(`git push` の直送。origin も GitHub も通らない)ビルドする。戻り値はビルド(fm-align)の終了コード
func sendAndBuildAlignment(hostSpec: RemoteHostSpec, layout: RemoteLayout,
                           prepared: AlignPrepared, io: AlignIO = .stdout) throws -> Int32 {
    let push = try runInheritedSSH(RemoteAlignPlan.pushArguments(
        repoRoot: prepared.repoRoot.path, sshTarget: hostSpec.sshTarget, toolRoot: layout.toolRoot,
        commit: prepared.commit), stdoutToStderr: io.toStderr)
    guard push == 0 else {
        throw RemoteDispatchError.remoteSetupFailed(
            "could not send \(prepared.commit.prefix(7)) to \(hostSpec.sshTarget):\(layout.toolRoot) (git push exited \(push);"
            + " is the runner set up? run `fleetest remote setup`)")
    }
    return try runRemoteAlignment(hostSpec: hostSpec, layout: layout, prepared: prepared, io: io)
}

private func runRemoteAlignment(hostSpec: RemoteHostSpec, layout: RemoteLayout, prepared: AlignPrepared,
                                io: AlignIO) throws -> Int32 {
    guard let executable = ExecutablePath.current else {
        throw RemoteDispatchError.remoteSetupFailed("could not resolve the local alignment executable")
    }
    let temporary = try Shell.run(setupSSHBase + [hostSpec.sshTarget,
        "mktemp -d /tmp/fleetest-remote-align.XXXXXXXX"])
    guard temporary.status == 0 else {
        throw RemoteDispatchError.remoteSetupFailed(
            "could not create a temporary alignment directory (exit \(temporary.status))\n\(temporary.tail)")
    }
    let directory = temporary.output.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = "/tmp/fleetest-remote-align."
    let suffix = directory.dropFirst(prefix.count)
    guard directory.hasPrefix(prefix), suffix.count == 8,
          suffix.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
        throw RemoteDispatchError.remoteSetupFailed("the remote alignment directory could not be verified")
    }
    let helper = directory + "/fleetest"
    // 転送失敗ではリモート側の EXIT trap へ到達しないため、こちらでも回収する。
    defer {
        _ = try? Shell.run(setupSSHBase + [hostSpec.sshTarget,
            "rm -f -- \(RemoteShell.quote(helper)); rmdir -- \(RemoteShell.quote(directory)) 2>/dev/null || true"])
    }
    let transfer = try runInheritedSSH(setupSCPBase + [executable.path, "\(hostSpec.sshTarget):\(helper)"],
                                       stdoutToStderr: io.toStderr)
    guard transfer == 0 else {
        throw RemoteDispatchError.remoteSetupFailed("could not copy the alignment executable (scp exited \(transfer))")
    }
    return try runInheritedSSH(setupSSHBase + [hostSpec.sshTarget,
        RemoteSetupPlan.alignRevisionCommand(layout: layout, revision: prepared.commit, digest: prepared.digest,
                                             helperPath: helper, developerDir: prepared.developerDir)],
        stdoutToStderr: io.toStderr)
}

/// `fleetest-devicepoll` / `fleetest-mcp` の後回しのビルドを、**dispatch.lock を外した後**にランナーの裏ジョブとして起こす
/// (`RemoteAlignPlan.deferredBuildCommand`)。失敗は警告1行(align の成否を変えない。次の align が「後回しが未成功」で撃ち直す)
func startDeferredBuild(hostSpec: RemoteHostSpec, layout: RemoteLayout, prepared: AlignPrepared,
                        io: AlignIO = .stdout) {
    let status = (try? runInheritedSSH(setupSSHBase + ["-n", hostSpec.sshTarget,
        RemoteAlignPlan.deferredBuildCommand(layout: layout, digest: prepared.digest,
                                             developerDir: prepared.developerDir)],
        stdoutToStderr: io.toStderr)) ?? -1
    if status == 0 {
        io.say("deferred build of \(RemoteAlignPlan.deferredProducts.joined(separator: "/")) started"
            + " (log: \(RemoteAlignPlan.deferredLogPath(layout: layout)))")
    } else {
        io.say("warning: could not start the deferred build of \(RemoteAlignPlan.deferredProducts.joined(separator: "/"))"
            + " on \(hostSpec.sshTarget) (ssh exited \(status)) — monitor streaming may be missing until the next align")
    }
}

/// アラインのビルドに使う Xcode。**ディスパッチと同じ解決**(登録簿の pin > build 一致 > 製品版一致。
/// `RemoteRunDispatcher.resolveXcodeSelection` と同じ入力)を通す —— 別に決めると、照合した Xcode と
/// ビルドした Xcode が食い違う。列挙できない・一致しない(refused)ときは ambient(従来どおり)で、refused は1行言う
func alignmentDeveloperDir(hostSpec: RemoteHostSpec) -> String? {
    let pin = LocalConfig.load().remoteHosts?.first { $0.host == hostSpec.sshTarget }?.developerDir
    guard let listing = try? Shell.run(setupSSHBase + [hostSpec.sshTarget, XcodeSelection.listCommand]),
          listing.status == 0 else {
        return XcodeSelection.resolve(localFingerprint: nil, installed: [], pin: pin).developerDir
    }
    let outcome = XcodeSelection.resolve(localFingerprint: ToolchainFingerprint.current(),
                                         installed: XcodeSelection.parse(listing.output), pin: pin)
    if case .refused(let reason) = outcome {
        ConsoleOut.err("⚠️ \(hostSpec.sshTarget): building with the runner's default Xcode — \(reason)")
    }
    return outcome.developerDir
}

/// `echo $HOME; <RemoteProbe.consoleUserCommand>; id -un` の到達確認(RemoteRunDispatcher.resolveLayout
/// と同じ規律だが private のため複製する)。session が nil でも home が取れていれば
/// ログイン判定だけスキップして続行する(古い macOS 等の想定外出力への fallback)。
/// `Setup` と `Align` が共有する
func remoteReach(hostSpec: RemoteHostSpec)
    -> (session: RemoteSessionInfo?, home: String?, error: String?) {
    guard let result = try? Shell.run(
        setupSSHBase + [hostSpec.sshTarget, "echo $HOME; \(RemoteProbe.consoleUserCommand); id -un"]) else {
        return (nil, nil, "ssh failed to run")
    }
    guard result.status == 0 else {
        return (nil, nil, "cannot reach \(hostSpec.sshTarget) over ssh (status \(result.status))"
            + " — check the host name and keys; BatchMode disables password prompts\n\(result.tail)")
    }
    if let session = RemoteProbe.parseSessionInfo(result.output) {
        return (session, session.home, nil)
    }
    let firstLine = (result.output.split(separator: "\n", maxSplits: 1,
                                          omittingEmptySubsequences: false).first ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !firstLine.isEmpty else {
        return (nil, nil, "could not determine $HOME on \(hostSpec.sshTarget)")
    }
    return (nil, firstLine, nil)
}

// MARK: - dispatch.lock (RR-18.3 規則2)
//
// align/install はリモートの `<base>/tool/.build` バイナリを再ビルドで差し替えるため、
// 稼働中の dispatch へ重ねるとその dispatch を SIGKILL する(「E2E 中に swift build を
// 打たない」と同型)。align/setup に `--force-lock` は無いので
// RemoteRunDispatcher.acquireDispatchLock と違い強制取得の分岐を持たない。

/// 取得。成功なら nil、失敗ならそのまま表示できるメッセージ文字列を返す
/// (RemoteRunDispatcher.acquireDispatchLock と同じ status 判定: 255 = ssh 到達不能、
/// それ以外の非0 = ロック保持中 → readCommand で保持者を読んで alignHeldMessage を組み立てる)
func acquireRemoteDispatchLock(hostSpec: RemoteHostSpec, layout: RemoteLayout) -> String? {
    let info = RemoteDispatchLockInfo.now(
        issuerHost: ProcessInfo.processInfo.hostName, pid: ProcessInfo.processInfo.processIdentifier,
        issuer: LocalConfig.resolveIssuerId())
    guard let result = try? Shell.run(setupSSHBase + [hostSpec.sshTarget,
        RemoteDispatchLock.acquireCommand(home: layout.home, info: info)]) else {
        return "ssh failed to run"
    }
    guard result.status == 0 else {
        guard result.status != 255 else {
            return "cannot reach \(hostSpec.sshTarget) over ssh (status 255)\n\(result.tail)"
        }
        let existing = try? Shell.run(setupSSHBase + [hostSpec.sshTarget, RemoteDispatchLock.readCommand(home: layout.home)])
        let existingInfo = existing.flatMap { RemoteDispatchLock.decode($0.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return RemoteDispatchLock.alignHeldMessage(existingInfo)
    }
    return nil
}

/// 解放。失敗しても警告1行(run の成否を変えない。RemoteRunDispatcher.releaseDispatchLock と同じ規律)
func releaseRemoteDispatchLock(hostSpec: RemoteHostSpec, layout: RemoteLayout, io: AlignIO = .stdout) {
    let result = try? Shell.run(setupSSHBase + [hostSpec.sshTarget, RemoteDispatchLock.releaseCommand(home: layout.home)])
    if result?.status != 0 {
        io.say("warning: failed to release the dispatch lock on \(hostSpec.sshTarget)"
            + " — clear it manually if the next align/setup is refused")
    }
}

// MARK: - 揃える(`remote align` と `run --align` の共通の本体)

enum RemoteAlign {
    enum Outcome: Equatable {
        case alreadyAligned(commit: String)
        case aligned(commit: String)
    }

    /// 宛先のランナーを手元(`toolRev` があればその版)に揃える。同じなら何もしない(ロックも取らない)。
    /// - `guarded`: `run --align` 用。**この機械が古い・分岐しているときにランナーを巻き戻さない**
    ///   (`RemoteAlignPlan.runAlignDecision`・RR-18.3 規則1)。`remote align` は人が名指しした操作なので撃つ
    /// - 失敗は `RemoteDispatchError.remoteSetupFailed`(呼び手がそのまま表示する)
    static func execute(resolved: ResolvedRemoteHost, repoRoot: URL, toolRev: String?, guarded: Bool,
                        io: AlignIO) throws -> Outcome {
        let hostSpec = resolved.hostSpec
        let prepared = try prepareAlignment(hostSpec: hostSpec, repoRoot: repoRoot, toolRev: toolRev, io: io)

        io.say("==> reach: checking \(hostSpec.sshTarget)...")
        let (session, home, reachError) = remoteReach(hostSpec: hostSpec)
        guard let home else {
            throw RemoteDispatchError.remoteSetupFailed(reachError ?? "unreachable")
        }
        if let session, !session.isLoggedIn {
            throw RemoteDispatchError.remoteSetupFailed(
                "\(hostSpec.sshTarget) is sitting at the login window (console user: "
                + "\(session.consoleUser), expected: \(session.sshUser)) — unlock and log in on the "
                + "runner, then retry (RR-5)")
        }
        let issuer = try resolveLayoutIssuer()
        let layout = RemoteLayout(base: RemoteLayout.resolveBase(resolved.remoteDirRaw, home: home),
                                  issuer: issuer, home: home)

        let state = alignmentProbe(hostSpec: hostSpec, layout: layout, prepared: prepared)
        if guarded,
           case .refuse(let relation) = RemoteAlignPlan.runAlignDecision(
               localDigest: prepared.digest, remote: state?.tool,
               relation: { revisionRelation(repoRoot: repoRoot, localRevision: prepared.base,
                                            remoteRevision: $0.base) }),
           let remote = state?.tool {
            throw RemoteDispatchError.remoteSetupFailed(
                "--align did not touch \(hostSpec.sshTarget): "
                + RemoteCompat.relationAdvice(relation, localIssuer: issuer,
                                              remoteSnapshotIssuer: remote.snapshotIssuer))
        }

        // 同じなら何もしない(ロックも取らない・送らない・ビルドしない)
        if let state, RemoteAlignPlan.isAlreadyAligned(localDigest: prepared.digest,
                                                       developerDir: prepared.developerDir, state: state) {
            io.say("✅ already aligned to \(prepared.commit.prefix(7)) (same contents and toolchain; nothing sent or built)")
            return .alreadyAligned(commit: prepared.commit)
        }

        // align は稼働中バイナリを差し替えるので、走っている dispatch と衝突しないことを
        // 先に確かめる(RR-18.3 規則2)。**ロックを外すのは後回しのビルドを起こす前**
        if let failure = acquireRemoteDispatchLock(hostSpec: hostSpec, layout: layout) {
            throw RemoteDispatchError.remoteSetupFailed(failure)
        }
        var lockHeld = true
        defer { if lockHeld { releaseRemoteDispatchLock(hostSpec: hostSpec, layout: layout, io: io) } }

        io.say("==> align: sending \(toolRev == nil ? "the working tree" : "the revision"), building the remote clone, and safely retiring FM...")
        let alignStatus = try sendAndBuildAlignment(hostSpec: hostSpec, layout: layout, prepared: prepared, io: io)
        guard alignStatus == 0 else {
            throw RemoteDispatchError.remoteSetupFailed(
                "build or FM resident alignment failed (exit \(alignStatus); see output above)")
        }
        releaseRemoteDispatchLock(hostSpec: hostSpec, layout: layout, io: io)
        lockHeld = false
        startDeferredBuild(hostSpec: hostSpec, layout: layout, prepared: prepared, io: io)
        io.say("✅ aligned to \(prepared.commit.prefix(7)) and built; FM maintenance completed")
        return .aligned(commit: prepared.commit)
    }
}
