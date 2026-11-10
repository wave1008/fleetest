// RemoteSetupCommand.swift
// `fleetest remote setup` / `teardown` / `align` / `exec` (RR-14)。
// 純粋ロジックは Sources/FTRemote/RemoteSetup.swift 側(RemoteSetupPlan、単体テスト対象)。

import ArgumentParser
import Darwin
import FTBridgeClient
import FTCore
import FTRemote
import Foundation


/// 進行の1行出力。**print は使わない** —— stdout が端末でないとき libc の行バッファが効かず、
/// 分単位かかる install/align の進行が最後まで出ない(ログへリダイレクトすると「止まったのか
/// 進んでいるのか」が判らない)。RemoteRunDispatcher.log の cliRun 側と同じ規律
private func say(_ message: String) {
    ConsoleOut.out(message)
}

/// `remote exec` の宛先解決アナウンス専用。stdout は転送先コマンドの出力(機械可読の場合が
/// ある: `-- api device-catalog` 等)そのままの契約なので、stdout に混ぜない
private func sayStderr(_ message: String) {
    ConsoleOut.err(message)
}


/// 作業フォルダの Package.swift のツール依存を今のクローンへ向け直す(`RemoteSetupPlan.repointedToolDependency`)。
/// 読みは stdout だけ(ssh の警告を中身に混ぜて書き戻さない)。直すものが無ければ skip
private func repointWorkManifest(hostSpec: RemoteHostSpec,
                                 layout: RemoteLayout) -> (status: RemoteSetupStepStatus, detail: String) {
    let manifest = RemoteSetupPlan.workManifestPath(layout: layout)
    guard let read = try? Shell.runData(setupSSHBase + [hostSpec.sshTarget,
                                                        RemoteSetupPlan.readWorkManifestCommand(layout: layout)]) else {
        return (.fail, "could not read \(manifest) on the remote")
    }
    if read.status == 1 { return (.skip, "") }
    guard read.status == 0, let content = String(data: read.data, encoding: .utf8) else {
        return (.fail, "could not read \(manifest) on the remote (exit \(read.status))")
    }
    guard let repointed = RemoteSetupPlan.repointedToolDependency(manifest: content, layout: layout) else {
        return (.skip, "")
    }
    let write = try? Shell.run(setupSSHBase + [hostSpec.sshTarget,
                                               RemoteSetupPlan.writeWorkManifestCommand(layout: layout,
                                                                                        readByteCount: read.data.count)],
                               stdin: Data(repointed.content.utf8))
    guard let write, write.status == 0 else {
        return (.fail, "could not rewrite \(manifest) on the remote (exit \(write?.status ?? -1))\n\(write?.tail ?? "")")
    }
    return (.ok, "repointed the tool dependency in Package.swift from \(repointed.previousPath) to \(layout.toolRoot)")
}


extension RemoteCommand {

    struct Setup: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "setup",
            abstract: "Provision a remote Mac to receive --runner dispatches (idempotent)",
            discussion: "Steps: local → reach → preflight → install → align → verify "
                + "(RR-14). Exit codes match install.sh: "
                + "0 = done / 2 = stopped with steps left for a human / 1 = failed.")

        @Argument(help: "Remote runner to set up: a registered machine (fleetest remote machines) or a raw user@host/host")
        var runner: String

        @Option(name: .customLong("remote-dir"),
                help: "Runner-only base directory on the remote host (default: the machine registry's entry, or ~/fleetest-runner)")
        var remoteDir: String?

        // ArgumentHelp は文字列**リテラル**からしか作れない(連結した String は渡せない)。
        // 長い説明は ArgumentHelp(...) で明示的に包む
        @Option(help: ArgumentHelp("Project name to install on the remote (default: the local project resolution — "
            + "the only TestProjects/ entry, or LocalConfig.defaultProject)"))
        var project: String?

        @Option(help: ArgumentHelp("Run profile for the verification dispatch. Setup is not confirmed working "
            + "until one real dispatch passes (RR-14, decision 3)"))
        var profile: String?

        @Option(help: "Scenario ID to run for verification (defaults to the whole --profile)")
        var scenario: String?

        @Flag(name: .customLong("skip-verify"), help: "Skip the verification dispatch")
        var skipVerify = false

        func run() async throws {
            let resolved = try RemoteHostResolver.resolve(rawHost: runner, remoteDirOverride: remoteDir)
            let hostSpec = resolved.hostSpec
            resolved.announce()

            var recorded: [(name: String, status: RemoteSetupStepStatus, detail: String)] = []
            func emit(_ name: String, _ status: RemoteSetupStepStatus, _ detail: String) {
                recorded.append((name, status, detail))
                say(RemoteSetupStepLine.render(name: name, status: status, detail: detail))
            }
            // 常にここへ落とす: 途中で止まった場合も含め、最後に必ず集計を出す
            // (CLAUDE.md「画面は各ステップ1行(逐次)+ 集計だけ」)。ExitCode を投げて終わるので
            // 呼び出し側に return は要らない(Never)
            func summarizeAndExit() throws -> Never {
                say("")
                say("──────── remote setup results ────────")
                say(RemoteSetupSummary(statuses: recorded.map(\.status)).line)
                for step in recorded where step.status == .warn || step.status == .fail {
                    say(RemoteSetupStepLine.render(name: step.name, status: step.status, detail: step.detail))
                }
                // install.sh と同じ終了コードの語彙(0=完了 / 2=必須は通ったが未完の項目がある /
                // 1=必須で停止)。**warn を 0 にしない** —— preflight の needs-manual や
                // 検証ディスパッチ未実施はここで止まっており、0 を返すと呼び出し側が完了と読む
                if recorded.contains(where: { $0.status == .fail }) { throw ExitCode(1) }
                throw ExitCode(recorded.contains(where: { $0.status == .warn }) ? 2 : 0)
            }

            // ローカル側の前提はネットワークより先に解く。後ろに置くと、--project の指定漏れが
            // ssh 往復とリモートの preflight を払った後に「install の失敗」として現れる
            guard let repoRoot = try? RepoRoot.find() else {
                emit("local", .fail,
                     "cannot resolve the local tool root (run this inside the fleetest repo)")
                try summarizeAndExit()
            }
            let resolvedProject: TestProject
            do {
                resolvedProject = try ScenarioHost.project(named: project)
            } catch {
                emit("local", .fail, "cannot resolve the local project: \(error.localizedDescription)")
                try summarizeAndExit()
            }
            emit("local", .ok, "project \(resolvedProject.name)")

            say("==> reach: checking \(hostSpec.sshTarget)...")
            let (session, home, reachError) = remoteReach(hostSpec: hostSpec)
            guard let home else {
                emit("reach", .fail, reachError ?? "unreachable")
                try summarizeAndExit()
            }
            if let session {
                guard session.isLoggedIn else {
                    emit("reach", .fail,
                         "\(hostSpec.sshTarget) is sitting at the login window (console user: "
                         + "\(session.consoleUser), expected: \(session.sshUser)) — unlock and log in on the "
                         + "runner, then retry (RR-5)")
                    try summarizeAndExit()
                }
                emit("reach", .ok, "reachable, logged in as \(session.sshUser)")
            } else {
                emit("reach", .warn, "could not determine the remote console login state — skipping the login check")
            }

            let issuer: String
            do {
                issuer = try resolveLayoutIssuer()
            } catch {
                emit("issuer", .fail, error.localizedDescription)
                try summarizeAndExit()
            }
            let layout = RemoteLayout(base: RemoteLayout.resolveBase(resolved.remoteDirRaw, home: home),
                                      issuer: issuer, home: home)

            let stamp = "\(Int(Date().timeIntervalSince1970))-\(ProcessInfo.processInfo.processIdentifier)"

            // MARK: preflight

            say("==> preflight: copying and running Scripts/preflight.sh --runner on \(hostSpec.sshTarget)...")
            let localPreflight = repoRoot.appendingPathComponent("Scripts/preflight.sh").path
            let remotePreflight = "/tmp/fleetest-remote-setup-\(stamp)-preflight.sh"
            let preflightScpStatus = (try? runInheritedSSH(
                setupSCPBase + [localPreflight, "\(hostSpec.sshTarget):\(remotePreflight)"])) ?? -1
            guard preflightScpStatus == 0 else {
                emit("preflight", .fail, "failed to copy Scripts/preflight.sh to the remote (scp exited \(preflightScpStatus))")
                try summarizeAndExit()
            }
            let preflightCmd = RemoteSetupPlan.runAndCleanupCommand(
                remotePath: remotePreflight,
                args: RemoteSetupPlan.preflightArgs(base: layout.base, workDir: layout.workDir))
            let preflightStatus = (try? runInheritedSSH(setupSSHBase + [hostSpec.sshTarget, preflightCmd])) ?? -1
            switch RemoteSetupPlan.preflightVerdict(exitCode: preflightStatus) {
            case .ready:
                emit("preflight", .ok, "ready")
            case .needsManual:
                emit("preflight", .warn, "needs manual steps on the remote (see output above) — fix them, "
                    + "then re-run `fleetest remote setup` (it is idempotent)")
                try summarizeAndExit()
            case .blocked:
                emit("preflight", .fail, "blocked (see output above)")
                try summarizeAndExit()
            case .unknown(let code):
                emit("preflight", .fail, "unexpected exit code \(code) (see output above)")
                try summarizeAndExit()
            }

            // MARK: install

            say("==> install: copying and running Scripts/install.sh on \(hostSpec.sshTarget)"
                + " (first run can take several minutes)...")

            // install/align は稼働中バイナリを差し替えるので、走っている dispatch と衝突しない
            // ことを先に確かめる(RR-18.3 規則2)。verify の dispatcher が
            // 同じロックを自分で取るので、verify より前に必ず解放する
            var dispatchLockHeld = false
            defer {
                if dispatchLockHeld {
                    releaseRemoteDispatchLock(hostSpec: hostSpec, layout: layout)
                }
            }
            if let failure = acquireRemoteDispatchLock(hostSpec: hostSpec, layout: layout) {
                emit("install", .fail, failure)
                try summarizeAndExit()
            }
            dispatchLockHeld = true

            let mkdirStatus = (try? Shell.run(
                setupSSHBase + [hostSpec.sshTarget, RemoteSetupPlan.ensureWorkDirCommand(layout: layout)]))?.status ?? -1
            guard mkdirStatus == 0 else {
                emit("install", .fail, "could not create \(layout.workDir) on the remote (mkdir exited \(mkdirStatus))")
                try summarizeAndExit()
            }
            let repoint = repointWorkManifest(hostSpec: hostSpec, layout: layout)
            if repoint.status != .skip { emit("workspace", repoint.status, repoint.detail) }
            if repoint.status == .fail { try summarizeAndExit() }
            let localInstall = repoRoot.appendingPathComponent("Scripts/install.sh").path
            let remoteInstall = "/tmp/fleetest-remote-setup-\(stamp)-install.sh"
            let installScpStatus = (try? runInheritedSSH(
                setupSCPBase + [localInstall, "\(hostSpec.sshTarget):\(remoteInstall)"])) ?? -1
            guard installScpStatus == 0 else {
                emit("install", .fail, "failed to copy Scripts/install.sh to the remote (scp exited \(installScpStatus))")
                try summarizeAndExit()
            }
            let installArgs = RemoteSetupPlan.installArgs(
                workDir: layout.workDir, projectName: resolvedProject.name, toolRoot: layout.toolRoot)
            let installCmd = RemoteSetupPlan.runAndCleanupCommand(remotePath: remoteInstall, args: installArgs)
            let installStatus = (try? runInheritedSSH(setupSSHBase + [hostSpec.sshTarget, installCmd])) ?? -1
            guard installStatus == 0 else {
                emit("install", .fail, "install.sh exited with status \(installStatus) (see output above)")
                try summarizeAndExit()
            }
            emit("install", .ok, "installed at \(layout.base)")

            // MARK: align

            say("==> align: sending the working tree, building the remote clone, and safely retiring FM...")
            let prepared: AlignPrepared
            do {
                prepared = try prepareAlignment(hostSpec: hostSpec, repoRoot: repoRoot)
            } catch {
                emit("align", .fail, error.localizedDescription)
                try summarizeAndExit()
            }
            if alignmentAlreadyDone(hostSpec: hostSpec, layout: layout, prepared: prepared) {
                emit("align", .ok, "already aligned (same contents and toolchain; nothing sent or built)")
            } else {
                let alignStatus: Int32
                do {
                    alignStatus = try sendAndBuildAlignment(hostSpec: hostSpec, layout: layout, prepared: prepared)
                } catch {
                    emit("align", .fail, error.localizedDescription)
                    try summarizeAndExit()
                }
                guard alignStatus == 0 else {
                    emit("align", .fail, "build or FM resident alignment failed (exit \(alignStatus); see output above)")
                    try summarizeAndExit()
                }
                emit("align", .ok, "aligned to \(prepared.commit.prefix(7)) and built; FM maintenance completed")
            }
            releaseRemoteDispatchLock(hostSpec: hostSpec, layout: layout)
            dispatchLockHeld = false

            // MARK: verify

            if let profile, !skipVerify {
                let what = scenario.map { "scenario \($0)" } ?? "profile \(profile)"
                say("==> verify: dispatching \(what) to \(hostSpec.sshTarget) (this is the real success gate)...")
                let dispatcher = RemoteRunDispatcher(
                    host: hostSpec, remoteDirRaw: resolved.remoteDirRaw, localRepoRoot: repoRoot,
                    hostLabel: runner)
                do {
                    let (scopedNames, scopedHost) = try machineScopedDeviceFilter(
                        project: resolvedProject, profile: profile, targetMachine: runner)
                    let exitCode = try await dispatcher.dispatch(
                        project: resolvedProject, profile: profile,
                        scenarios: scenario.map { [$0] } ?? [], folders: [],
                        deviceNames: scopedNames, deviceMachine: scopedHost,
                        noLPT: false, lptHistoryRuns: nil,
                        performanceMode: false,
                        localJUnitPath: nil, remoteTimeoutSeconds: nil)
                    if exitCode == 0 {
                        emit("verify", .ok, "dispatch to \(hostSpec.sshTarget) passed")
                    } else {
                        emit("verify", .fail, "dispatch exited with status \(exitCode)")
                    }
                } catch {
                    emit("verify", .fail, "dispatch failed: \(error.localizedDescription)")
                }
            } else {
                emit("verify", .warn, skipVerify
                    ? "skipped (--skip-verify) — not yet verified with a real dispatch"
                    : "skipped (no --profile given) — not yet verified with a real dispatch")
            }

            try summarizeAndExit()
        }
    }

    struct Teardown: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "teardown",
            abstract: "Delete the remote base directory of a runner (destructive)")

        @Argument(help: "Remote runner to delete: a registered machine (fleetest remote machines) or a raw user@host/host")
        var runner: String

        @Option(name: .customLong("remote-dir"),
                help: "Runner-only base directory on the remote host (default: the machine registry's entry, or ~/fleetest-runner)")
        var remoteDir: String?

        @Flag(help: "Do not prompt for confirmation")
        var yes = false

        func run() async throws {
            let resolved = try RemoteHostResolver.resolve(rawHost: runner, remoteDirOverride: remoteDir)
            let hostSpec = resolved.hostSpec
            resolved.announce()

            say("==> reach: checking \(hostSpec.sshTarget)...")
            let (session, home, reachError) = remoteReach(hostSpec: hostSpec)
            guard let home else {
                say(reachError ?? "unreachable")
                throw ExitCode(1)
            }
            if let session, !session.isLoggedIn {
                say("\(hostSpec.sshTarget) is sitting at the login window (console user: "
                    + "\(session.consoleUser), expected: \(session.sshUser)) — unlock and log in on the "
                    + "runner, then retry (RR-5)")
                throw ExitCode(1)
            }

            let layout: RemoteLayout
            do {
                layout = RemoteLayout(base: RemoteLayout.resolveBase(resolved.remoteDirRaw, home: home),
                                      issuer: try resolveLayoutIssuer(), home: home)
            } catch {
                say(error.localizedDescription)
                throw ExitCode(1)
            }

            do {
                try RemoteSetupPlan.validateUninstallBase(layout.base, home: home)
            } catch {
                say(error.localizedDescription)
                throw ExitCode(1)
            }
            guard confirmUninstall(base: layout.base, host: hostSpec.sshTarget) else {
                say("cancelled (pass --yes to skip the confirmation prompt)")
                throw ExitCode(1)
            }
            say("==> teardown: deleting \(layout.base) on \(hostSpec.sshTarget)...")
            let command = RemoteSetupPlan.uninstallCommand(base: layout.base)
            let status = (try? runInheritedSSH(setupSSHBase + [hostSpec.sshTarget, command])) ?? -1
            guard status == 0 else {
                say("rm exited with status \(status)")
                throw ExitCode(1)
            }
            say("✅ deleted \(layout.base)")
        }

        /// `--yes` があれば無条件に許可。無ければ TTY からのみ確認を取る(非対話セッションは
        /// 確認できないので拒否する。破壊的操作は必ず人の確認を経る)
        private func confirmUninstall(base: String, host: String) -> Bool {
            if yes { return true }
            guard isatty(fileno(stdin)) != 0 else { return false }
            // 入力を同じ行で待つので改行を付けない(ここは TTY 限定なのでバッファ懸念は無い)
            ConsoleOut.out(
                Data("This permanently deletes \(base) on \(host). Type 'yes' to continue: ".utf8))
            guard let line = readLine() else { return false }
            return line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "yes"
        }
    }

    struct Align: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "align",
            abstract: "Send the local working tree (or --tool-rev) to a runner and build it"
                + " (the align step of `remote setup` alone; RR-14)")

        @Argument(help: "Remote runner to align: a registered machine (fleetest remote machines) or a raw user@host/host")
        var runner: String

        @Option(name: .customLong("remote-dir"),
                help: "Runner-only base directory on the remote host (default: the machine registry's entry, or ~/fleetest-runner)")
        var remoteDir: String?

        @Option(name: .customLong("tool-rev"),
                help: ArgumentHelp("Send this commit (any commit-ish of the local clone, e.g. HEAD) as is instead of the working "
                    + "tree. Use it to run the version before a fix on one runner while another runner holds the working tree "
                    + "(pair with `fleetest run --tool-rev <same>`)"))
        var toolRev: String?

        func run() async throws {
            let resolved = try RemoteHostResolver.resolve(rawHost: runner, remoteDirOverride: remoteDir)
            resolved.announce()

            guard let repoRoot = try? RepoRoot.find() else {
                throw RemoteDispatchError.remoteSetupFailed(
                    "cannot resolve the local tool root (run this inside the fleetest repo)")
            }
            _ = try RemoteAlign.execute(resolved: resolved, repoRoot: repoRoot, toolRev: toolRev,
                                        guarded: false, io: .stdout)
        }
    }

    struct Exec: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "exec",
            abstract: "Run `fleetest <args>` on a remote runner and relay its output and exit code",
            discussion: "The generic transport for one-shot queries and operations "
                + "(RR-14): do not add a dedicated ssh path for a new use case, use this. "
                + "Everything after <runner> is passed through verbatim, so --remote-dir must come before it.\n"
                + "  fleetest remote exec mac2 -- doctor --fm-only\n"
                + "  fleetest remote exec --remote-dir ~/runner mac2 -- api device-catalog")

        @Argument(help: "Remote runner to run on: a registered machine (fleetest remote machines) or a raw user@host/host")
        var runner: String

        @Option(name: .customLong("remote-dir"),
                help: "Runner-only base directory on the remote host (default: the machine registry's entry, or ~/fleetest-runner)")
        var remoteDir: String?

        // 設計文書(RR-14)は `fleetest --host <name> <サブコマンド>` の形で
        // 書いているが、ArgumentParser のサブコマンド解決と `run --host` の意味が衝突するため
        // `remote exec <runner> -- <args>` に変えた(トップレベルに --host オプションは無い)
        @Argument(parsing: .captureForPassthrough,
                  help: "The fleetest subcommand and its arguments to run remotely, e.g. -- doctor --fm-only")
        var args: [String] = []

        func run() async throws {
            var relayed = args
            if relayed.first == "--" { relayed.removeFirst() }
            guard !relayed.isEmpty else {
                throw ValidationError("no fleetest subcommand given (usage: remote exec <runner> -- <subcommand> [args...])")
            }
            guard !relayed.contains("--runner") else {
                throw ValidationError("--runner cannot be relayed through `remote exec` (no nested dispatch to another runner)")
            }
            let resolved = try RemoteHostResolver.resolve(rawHost: runner, remoteDirOverride: remoteDir)
            let hostSpec = resolved.hostSpec
            // 端末で打ったときだけ。拡張は配信・メトリクス・fan-out で1機に十数本を立てるので、
            // 毎本同じ行が並ぶ(fan-out の親が機械と宛先を1行出す = RemoteMonitorFanout)
            if isatty(STDERR_FILENO) != 0 { resolved.announce(toStderr: true) }

            // **-n: この ssh に stdin を読ませない**。読むと、続く本番の ssh へ渡すはずの stdin の先頭
            // (`api live serve` の最初のコマンド等)をここで食べて捨てる(実地: 他の機械の
            // 実機のライブ操作で最初の frame が返らなかった)
            let homeResult = try Shell.run(setupSSHBase + ["-n", hostSpec.sshTarget, "echo $HOME"])
            guard homeResult.status == 0 else {
                throw RemoteDispatchError.remoteSetupFailed(
                    "cannot reach \(hostSpec.sshTarget) over ssh (status \(homeResult.status))\n\(homeResult.tail)")
            }
            let home = homeResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !home.isEmpty else {
                throw RemoteDispatchError.remoteSetupFailed("could not determine $HOME on \(hostSpec.sshTarget)")
            }
            let layout = RemoteLayout(base: RemoteLayout.resolveBase(resolved.remoteDirRaw, home: home),
                                      issuer: try resolveLayoutIssuer(), home: home)
            let command = RemoteShell.remoteExecCommand(layout: layout, args: relayed)
            let status = try runInheritedSSH(setupSSHBase + [hostSpec.sshTarget, command])
            if status == 90 {
                ConsoleOut.err(
                    "the remote fleetest binary is missing — run `fleetest remote setup \(hostSpec.sshTarget)` first")
            } else if status == 91 {
                ConsoleOut.err(
                    "this issuer has no runner workspace on \(hostSpec.sshTarget) yet — run `fleetest remote setup "
                        + "\(hostSpec.sshTarget)` once for this issuer (RR-18)")
            }
            if status != 0 {
                throw ExitCode(status)
            }
        }
    }
}
