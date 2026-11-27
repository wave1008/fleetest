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
    /// 作業ツリー由来(`--tool-rev` ではない)。手元のビルド済みを送ってよい前提(`AlignPrebuilt.Conditions.fromWorkingTree`)
    let fromWorkingTree: Bool
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
                             base: revision.commit, developerDir: alignmentDeveloperDir(hostSpec: hostSpec),
                             fromWorkingTree: false)
    }
    let issuer = try resolveLayoutIssuer()
    let local: AlignSnapshot.LocalTree
    let commit: String
    let untracked: (count: Int, bytes: Int64)
    do {
        local = try AlignSnapshot.localTree(repoRoot: repoRoot, includeTestProjects: true)
        commit = try AlignSnapshot.commitToSend(repoRoot: repoRoot, local: local, issuer: issuer)
        untracked = try AlignSnapshot.untrackedSummary(repoRoot: repoRoot)
    } catch {
        throw RemoteDispatchError.remoteSetupFailed("could not snapshot the local working tree: \(error.localizedDescription)")
    }
    try RemoteSetupPlan.validateRevision(commit)
    io.say(RemoteAlignPlan.sendLine(commit: commit, isSnapshot: !local.isClean,
                                    untrackedCount: untracked.count, untrackedBytes: untracked.bytes))
    return AlignPrepared(repoRoot: repoRoot, commit: commit, digest: local.digest, base: local.head,
                         developerDir: alignmentDeveloperDir(hostSpec: hostSpec), fromWorkingTree: true)
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
    return RemoteAlignPlan.isAlreadyAligned(commit: prepared.commit, localDigest: prepared.digest, developerDir: prepared.developerDir,
                                            state: state)
}

/// 送って(`git push` の直送。origin も GitHub も通らない)ビルドする。戻り値はビルド(fm-align)の終了コード。
/// `probe` は送る前の照会(手元のビルド済みを送るかの予測に使う。nil = 照会が無い = ランナー側の照合に任せて送る)
func sendAndBuildAlignment(hostSpec: RemoteHostSpec, layout: RemoteLayout, prepared: AlignPrepared,
                           probe: RemoteAlignPlan.ProbeState?, io: AlignIO = .stdout) throws -> Int32 {
    let push = try runInheritedSSH(RemoteAlignPlan.pushArguments(
        repoRoot: prepared.repoRoot.path, sshTarget: hostSpec.sshTarget, toolRoot: layout.toolRoot,
        commit: prepared.commit), stdoutToStderr: io.toStderr)
    guard push == 0 else {
        throw RemoteDispatchError.remoteSetupFailed(
            "could not send \(prepared.commit.prefix(7)) to \(hostSpec.sshTarget):\(layout.toolRoot) (git push exited \(push);"
            + " is the runner set up? run `fleetest remote setup`)")
    }
    return try runRemoteAlignment(hostSpec: hostSpec, layout: layout, prepared: prepared, probe: probe, io: io)
}

private func runRemoteAlignment(hostSpec: RemoteHostSpec, layout: RemoteLayout, prepared: AlignPrepared,
                                probe: RemoteAlignPlan.ProbeState?, io: AlignIO) throws -> Int32 {
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
    // 手元のビルド済みの製品も、ヘルパーと同じ scp で同じディレクトリへ送る(`fleetest` はヘルパー自身 = 二重に送らない)
    let selection = selectPrebuiltProducts(prepared: prepared, probe: probe, executable: executable)
    let stagedNames = selection.files.map { RemoteShell.quote(directory + "/" + $0.lastPathComponent) }.joined(separator: " ")
    // 転送失敗ではリモート側の EXIT trap へ到達しないため、こちらでも回収する。
    defer {
        _ = try? Shell.run(setupSSHBase + [hostSpec.sshTarget,
            "rm -f -- \(RemoteShell.quote(helper)) \(stagedNames); rmdir -- \(RemoteShell.quote(directory)) 2>/dev/null || true"])
    }
    if !selection.files.isEmpty {
        let megabytes = selection.files.reduce(into: Int64(0)) {
            $0 += ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? NSNumber)?.int64Value ?? 0)
        } / 1_000_000
        io.say("==> align: sending \(selection.files.count) prebuilt product(s) with the alignment executable"
            + " (\(megabytes) MB): \(selection.files.map(\.lastPathComponent).joined(separator: ", "))")
    }
    let destination = selection.files.isEmpty ? helper : directory + "/"
    let transfer = try runInheritedSSH(
        setupSCPBase + [executable.path] + selection.files.map(\.path) + ["\(hostSpec.sshTarget):\(destination)"],
        stdoutToStderr: io.toStderr)
    guard transfer == 0 else {
        throw RemoteDispatchError.remoteSetupFailed("could not copy the alignment executable (scp exited \(transfer))")
    }
    return try runInheritedSSH(setupSSHBase + [hostSpec.sshTarget,
        RemoteSetupPlan.alignRevisionCommand(layout: layout, revision: prepared.commit, digest: prepared.digest,
                                             helperPath: helper, developerDir: prepared.developerDir,
                                             prebuilt: selection.plan.staged(in: directory))],
        stdoutToStderr: io.toStderr)
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
/// (255 = ssh 到達不能。それ以外は待機列の結果を `RemoteDispatchLock.alignRefusal` が文言にする)
func acquireRemoteDispatchLock(hostSpec: RemoteHostSpec, layout: RemoteLayout) -> String? {
    let info = RemoteDispatchLockInfo.now(
        issuerHost: ProcessInfo.processInfo.hostName, pid: ProcessInfo.processInfo.processIdentifier,
        issuer: LocalConfig.resolveIssuerId())
    // **待機列を1回だけ通す**(待たない取得も列を通す = RR-18.9。直接 mkdir すると先頭で待っている run を追い越し、
    // その run が照合した版のランナーを開始前に差し替える)。取れなければ自分のチケットを消して断る
    let ticket = RemoteDispatchQueue.resolveTicket(
        environment: ProcessInfo.processInfo.environment, issuer: LocalConfig.resolveIssuerId(),
        runGroup: nil, pid: ProcessInfo.processInfo.processIdentifier, now: Date())
    guard let result = try? Shell.run(setupSSHBase + [hostSpec.sshTarget,
        RemoteDispatchQueue.enqueueAndTryAcquireCommand(home: layout.home, ticket: ticket, info: info)]) else {
        return "ssh failed to run"
    }
    guard result.status != 255 else {
        return "cannot reach \(hostSpec.sshTarget) over ssh (status 255)\n\(result.tail)"
    }
    let outcome = RemoteDispatchQueue.parseOutcome(result.output, ticket: ticket)
    if outcome != .acquired {
        _ = try? Shell.run(setupSSHBase + [hostSpec.sshTarget,
                                           RemoteDispatchQueue.dequeueCommand(home: layout.home, ticket: ticket)])
    }
    guard let outcome else {
        return "could not read the dispatch queue on \(hostSpec.sshTarget) (status \(result.status))\n\(result.tail)"
    }
    return RemoteDispatchLock.alignRefusal(outcome)
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
    /// - `guarded`: `run --align` 用。**この機械が古い・分岐している・照会が読めないときにランナーを巻き戻さない**
    ///   (`RemoteAlignPlan.alignDecision`・RR-18.3 規則1)。`remote align` と `--tool-rev` 明示は人が名指しした操作なので撃つ
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
        // `--tool-rev` を明示したときは安全弁を掛けない(`RemoteAlignPlan.isGuarded`)。照会が読めないときは止める
        switch RemoteAlignPlan.alignDecision(
            guarded: RemoteAlignPlan.isGuarded(requested: guarded, toolRev: toolRev),
            localDigest: prepared.digest, probe: state,
            relation: { revisionRelation(repoRoot: repoRoot, localRevision: prepared.base, remoteRevision: $0.base) }) {
        case .proceed:
            break
        case .refuseUnreadable:
            throw RemoteDispatchError.remoteSetupFailed(
                "--align did not touch \(hostSpec.sshTarget): " + RemoteAlignPlan.unreadableProbeAdvice)
        case .refuse(let relation):
            throw RemoteDispatchError.remoteSetupFailed(
                "--align did not touch \(hostSpec.sshTarget): "
                + RemoteCompat.relationAdvice(relation, localIssuer: issuer,
                                              remoteSnapshotIssuer: state?.tool?.snapshotIssuer))
        }

        // 同じなら何もしない(ロックも取らない・送らない・ビルドしない)
        if let state, RemoteAlignPlan.isAlreadyAligned(commit: prepared.commit, localDigest: prepared.digest,
                                                       developerDir: prepared.developerDir, state: state) {
            io.say("✅ already aligned to \(prepared.commit.prefix(7)) (same contents and toolchain; nothing sent or built)")
            return .alreadyAligned(commit: prepared.commit)
        }

        // align は稼働中バイナリを差し替えるので、走っている dispatch と衝突しないことを
        // 先に確かめる(RR-18.3 規則2)。全製品のビルドもこのロックの中
        if let failure = acquireRemoteDispatchLock(hostSpec: hostSpec, layout: layout) {
            throw RemoteDispatchError.remoteSetupFailed(failure)
        }
        var lockHeld = true
        defer { if lockHeld { releaseRemoteDispatchLock(hostSpec: hostSpec, layout: layout, io: io) } }

        io.say("==> align: sending \(toolRev == nil ? "the working tree" : "the revision"), building the remote clone, and safely retiring FM...")
        let alignStatus = try sendAndBuildAlignment(hostSpec: hostSpec, layout: layout, prepared: prepared, probe: state, io: io)
        guard alignStatus == 0 else {
            throw RemoteDispatchError.remoteSetupFailed(
                "build or FM resident alignment failed (exit \(alignStatus); see output above)")
        }
        releaseRemoteDispatchLock(hostSpec: hostSpec, layout: layout, io: io)
        lockHeld = false
        io.say("✅ aligned to \(prepared.commit.prefix(7)) and built; FM maintenance completed")
        return .aligned(commit: prepared.commit)
    }
}
