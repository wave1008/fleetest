// RemoteAlignPlan.swift
// `remote align` / `remote setup` の align 段の純粋ロジック(直送の push・「同じなら何もしない」の判定・
// ランナーでのビルドの記録と後回しのビルド)。I/O は Sources/fleetest/RemoteSetupCommand.swift。
// 送るコミットと要約は `AlignSnapshot`(手元とランナーで同じ規則)。
//
// ランナーの記録(`<toolRoot>/.fleetest/align-built`)は4行: 要約 / developerDir(nil は `-`) /
// `xcodebuild -version` を1行に畳んだもの / 送ったコミット。**ビルドが全部成功した直後にだけ書く**
// (古い記録はビルドの前に消す = 途中で失敗した回の記録が次の判定に残らない)。

import FTCore
import Foundation

public enum RemoteAlignPlan {
    /// 記録・不明を表す値(行数を固定するための印)
    static let unknown = "-"

    /// 後回しにするビルドの製品。run の経路(ディスパッチ・run のフック)からは起動されず、モニターの配信と
    /// MCP だけが使う。**省かず後ろへ回すだけ**(無いとモニターの映像が出ない・版が古いと MCP が断られる)
    public static let deferredProducts = [StreamHelpers.devicepoll, "fleetest-mcp"]

    /// 記録に載せる `xcodebuild -version` の1行化(判定と記録で同じ式を使う)。**この式を呼ぶシェルは
    /// `DEVELOPER_DIR` を export 済みであること**(選んだ Xcode の版を読む)
    static let xcodeVersionOneLine = "xcodebuild -version 2>/dev/null | tr '\\n' ' ' | sed 's/ *$//'"

    // MARK: - ランナー上の置き場

    public static func builtRecordPath(layout: RemoteLayout) -> String { layout.toolRoot + "/.fleetest/align-built" }
    public static func deferredRecordPath(layout: RemoteLayout) -> String { layout.toolRoot + "/.fleetest/align-deferred" }
    public static func deferredLogPath(layout: RemoteLayout) -> String { layout.toolRoot + "/.fleetest/align-deferred.log" }

    // MARK: - 直送の push

    /// `git push` の argv。先頭の `GIT_SSH_COMMAND=…` は `/usr/bin/env` が環境変数として解釈する
    /// (`runInheritedSSH` は argv を env 経由で起こす)。ssh の引数は **SSHOptions を通す**(接続の上限・
    /// キープアライブ。無いと黙って死んだ回線を TCP の既定まで待つ)。
    /// ref はブランチにしない(ランナーのクローンは detached HEAD = checkout 中のブランチへの push は拒否される)。
    /// `--no-verify` は手元の pre-push フックを走らせない(送るのは作業ツリーの写しで、フックの対象はコミットの公開)
    public static func pushArguments(repoRoot: String, sshTarget: String, toolRoot: String,
                                     commit: String) -> [String] {
        let ssh = (["ssh"] + SSHOptions.batchConnectArgs + SSHOptions.keepAliveArgs)
            .map(RemoteShell.quote).joined(separator: " ")
        return ["GIT_SSH_COMMAND=\(ssh)", "git", "-C", repoRoot, "push", "--force", "--no-verify",
                "\(sshTarget):\(toolRoot)", "\(commit):\(AlignSnapshot.pushRef)"]
    }

    /// 送る前の1行(件数と合計の事実だけ。閾値は置かない)
    public static func sendLine(commit: String, isSnapshot: Bool, untrackedCount: Int, untrackedBytes: Int64) -> String {
        let megabytes = String(format: "%.1f", Double(untrackedBytes) / 1_048_576)
        let what = isSnapshot ? "working tree snapshot \(commit.prefix(7))" : "HEAD \(commit.prefix(7))"
        return "sending \(what) (untracked files included: \(untrackedCount), \(megabytes) MB)"
    }

    // MARK: - 照会(ssh 1往復)

    /// ランナーの状態を1往復で読む。出力は11行(`parseProbe`): `AlignSnapshot.remoteProbeCommand` の4行 +
    /// 記録の4行 + 後回しのビルドの記録 + 実行ファイルの有無(yes/no) + 今の `xcodebuild -version`。
    /// 読めない値は `-`(行数は常に11)。`developerDir` はビルドと同じ値(別に解決しない)
    public static func probeCommand(layout: RemoteLayout, developerDir: String?) -> String {
        let record = RemoteShell.quote(builtRecordPath(layout: layout))
        let deferred = RemoteShell.quote(deferredRecordPath(layout: layout))
        let binary = RemoteShell.quote(layout.binary)
        let devDir = developerDir.map { "export DEVELOPER_DIR=\(RemoteShell.quote($0)); " } ?? ""
        return devDir
            + AlignSnapshot.remoteProbeCommand(quotedToolRoot: RemoteShell.quote(layout.toolRoot)) + "; "
            + "for n in 1 2 3 4; do l=$(sed -n \"${n}p\" \(record) 2>/dev/null); printf '%s\\n' \"${l:--}\"; done; "
            + "l=$(head -1 \(deferred) 2>/dev/null); printf '%s\\n' \"${l:--}\"; "
            + "if [ -x \(binary) ]; then echo yes; else echo no; fi; "
            + "l=$(\(xcodeVersionOneLine)); printf '%s\\n' \"${l:--}\""
    }

    public struct BuildRecord: Equatable, Sendable {
        public let digest: String
        public let developerDir: String?
        public let xcodeVersion: String
        public let commit: String
        public init(digest: String, developerDir: String?, xcodeVersion: String, commit: String) {
            self.digest = digest
            self.developerDir = developerDir
            self.xcodeVersion = xcodeVersion
            self.commit = commit
        }
    }

    public struct DeferredRecord: Equatable, Sendable {
        public let digest: String
        public let exitCode: Int32
        public init(digest: String, exitCode: Int32) {
            self.digest = digest
            self.exitCode = exitCode
        }
    }

    public struct ProbeState: Equatable, Sendable {
        /// クローンが無い・git が読めないときは nil
        public let tool: AlignSnapshot.RemoteToolState?
        public let record: BuildRecord?
        public let deferred: DeferredRecord?
        public let binaryExists: Bool
        /// 今の Xcode の版(読めなければ `-`)
        public let xcodeVersion: String
        public init(tool: AlignSnapshot.RemoteToolState?, record: BuildRecord?, deferred: DeferredRecord?,
                    binaryExists: Bool, xcodeVersion: String) {
            self.tool = tool
            self.record = record
            self.deferred = deferred
            self.binaryExists = binaryExists
            self.xcodeVersion = xcodeVersion
        }
    }

    /// `probeCommand` の出力を読む。行数が足りなければ nil(= 判定できない = 呼び手は「揃っていない」へ倒す)
    public static func parseProbe(_ output: String) -> ProbeState? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 11 else { return nil }
        func value(_ index: Int) -> String? { lines[index].isEmpty || lines[index] == unknown ? nil : lines[index] }
        let record: BuildRecord? = {
            guard let digest = value(4), let xcode = value(6), let commit = value(7) else { return nil }
            return BuildRecord(digest: digest, developerDir: value(5), xcodeVersion: xcode, commit: commit)
        }()
        let deferred: DeferredRecord? = {
            guard let line = value(8) else { return nil }
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count == 2, let code = Int32(parts[1]) else { return nil }
            return DeferredRecord(digest: parts[0], exitCode: code)
        }()
        return ProbeState(tool: AlignSnapshot.parseRemoteProbe(Array(lines[0..<4])), record: record,
                          deferred: deferred, binaryExists: lines[9] == "yes", xcodeVersion: value(10) ?? unknown)
    }

    /// **同じなら何もしない**の判定。全部を満たすときだけ true(1つでも違えば送ってビルドする):
    /// ランナーのクローンの要約が手元と同じ / 成功したビルドの記録が同じ要約・同じ developerDir・同じ Xcode の版 /
    /// 後回しのビルドも同じ要約で成功 / 実行ファイルがある
    public static func isAlreadyAligned(localDigest: String, developerDir: String?, state: ProbeState) -> Bool {
        guard let tool = state.tool, tool.digest == localDigest,
              let record = state.record, record.digest == localDigest,
              record.developerDir == developerDir,
              record.xcodeVersion == state.xcodeVersion,
              let deferred = state.deferred, deferred.digest == localDigest, deferred.exitCode == 0,
              state.binaryExists else { return false }
        return true
    }

    // MARK: - ランナーでのビルド(fm-align の `--build-command`。`/bin/sh -c` で走る)

    /// 送ったコミットを checkout してビルドし、全部成功したら記録を書く。
    /// - `fleetest` と `fleetest-services` は必ずビルドする(run に要る。run のフックが隣の services を PATH へ足す)
    /// - `fleetest-simstream` / `fleetest-androidstream` はモニターの配信専用で、依存ターゲットがゼロ。
    ///   **記録があり・developerDir と Xcode の版が記録と同じ・前回のコミットから `Sources/<製品>` と
    ///   Package.swift / Package.resolved が無変更・実行ファイルがある** ときだけ省く(1つでも欠けたらビルド)。
    ///   差分が引けない(前回のコミットがランナーに無い)ときも `git diff --quiet` は非0 = ビルドに倒れる
    /// - `fleetest-devicepoll` / `fleetest-mcp` はここではビルドしない(`deferredBuildCommand`)
    public static func buildScript(layout: RemoteLayout, revision: String, digest: String,
                                   developerDir: String?) -> String {
        let record = RemoteShell.quote(builtRecordPath(layout: layout))
        let skip = "[ -n \"$ft_prev_rev\" ] && [ \"$ft_prev_dev\" = \"$ft_dev\" ] && [ \"$ft_prev_xc\" = \"$ft_xc\" ] "
            + "&& [ -x \"$ft_root/.build/debug/$1\" ] "
            + "&& git diff --quiet \"$ft_prev_rev\" \"$ft_rev\" -- \"Sources/$1\" Package.swift Package.resolved"
        let function = "ft_build() { if \(skip); then echo \"skipping $1 (unchanged since the last successful build)\"; "
            + "else swift build --product \"$1\"; fi; }"
        return "ft_root=\(RemoteShell.quote(layout.toolRoot)); ft_rec=\(record); "
            + "ft_dev=\(RemoteShell.quote(developerDir ?? unknown)); ft_rev=\(RemoteShell.quote(revision)); "
            + "ft_xc=$(\(xcodeVersionOneLine)); ft_xc=\"${ft_xc:--}\"; "
            + "ft_prev_dev=$(sed -n 2p \"$ft_rec\" 2>/dev/null); ft_prev_xc=$(sed -n 3p \"$ft_rec\" 2>/dev/null); "
            + "ft_prev_rev=$(sed -n 4p \"$ft_rec\" 2>/dev/null); "
            + "rm -f \"$ft_rec\" \(RemoteShell.quote(deferredRecordPath(layout: layout))) && "
            + "cd \"$ft_root\" && git checkout --detach \"$ft_rev\" && \(function) && "
            + "swift build --product fleetest && "
            + "ft_build \(StreamHelpers.simstream) && ft_build \(StreamHelpers.androidstream) && "
            + "swift build --product \(ServiceGatewayWire.relayProductName) && "
            + "mkdir -p \"$ft_root/.fleetest\" && "
            + "printf '%s\\n%s\\n%s\\n%s\\n' \(RemoteShell.quote(digest)) \"$ft_dev\" \"$ft_xc\" \"$ft_rev\" > \"$ft_rec\""
    }

    // MARK: - 後回しのビルド

    /// `fleetest-devicepoll` と `fleetest-mcp` を、dispatch.lock を外した後にランナーの裏ジョブとして順にビルドする。
    /// - 後ろへ回すだけで省かない(`deferredProducts`)
    /// - run の経路から起動されない・`fleetest` の実行ファイルには触らない(リンクだけ)・作業パッケージの
    ///   シナリオのビルドは別の `.build` なので SwiftPM のロックで競合しない
    /// - 出力は `align-deferred.log`、終わったら `<要約> <終了コード>` を `align-deferred` へ書く
    ///   (`isAlreadyAligned` が読む。失敗・実行中は記録が無い/0以外 = 次の align が撃ち直す)
    /// - ssh がすぐ返る形: nohup + 出力と stdin のリダイレクト + `&`。**`&` は `{ …; }` で nohup だけを包む**
    ///   (`a && b && nohup … &` と書くと列全体が裏の subshell になり、ssh の stdout を握ったまま返らない)。呼び手は `ssh -n` で撃つ
    public static func deferredBuildCommand(layout: RemoteLayout, digest: String, developerDir: String?) -> String {
        let devDirCmd = developerDir.map { "export DEVELOPER_DIR=\(RemoteShell.quote($0)); " } ?? ""
        let record = RemoteShell.quote(deferredRecordPath(layout: layout))
        let builds = deferredProducts.map { "swift build --product \($0)" }.joined(separator: " && ")
        let job = "\(builds); ft_exit=$?; printf '%s %s\\n' \(RemoteShell.quote(digest)) \"$ft_exit\" > \(record)"
        return "export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"; " + devDirCmd
            + "mkdir -p \(RemoteShell.quote(layout.toolRoot + "/.fleetest")) && "
            + "cd \(RemoteShell.quote(layout.toolRoot)) && rm -f \(record) && "
            + "{ nohup sh -c \(RemoteShell.quote(job)) > \(RemoteShell.quote(deferredLogPath(layout: layout))) "
            + "2>&1 < /dev/null & }"
    }
}
