// RemoteAlignPlan.swift
// `remote align` / `remote setup` の align 段の純粋ロジック(直送の push・「同じなら何もしない」の判定・
// ランナーでのビルドの記録・全製品のビルドと省略の条件)。I/O は Sources/fleetest/RemoteSetupCommand.swift。
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

    /// `fleetest` 以外の製品ごとの依存閉包のソースのディレクトリ(リポジトリ直下からの相対)。`buildScript` が
    /// 「前回の成功したビルドから閉包が無変更なら省く」に使う。**表に漏れがあると、変わった依存を見ずに古いバイナリを
    /// 残す(黙って誤る)** ので、`Package.swift` の依存と等号で突き合わせるテスト(`RemoteAlignPlanTests` の
    /// `testProductSourceClosureMatchesPackageManifest`)が砦。ターゲットを足す・依存を変えたらここも直す。
    /// `fleetest` は含めない(run に要り、閉包が大きく省いても得が小さい。常にビルドする)
    public static let productSourceClosure: [String: [String]] = [
        StreamHelpers.simstream: ["Sources/fleetest-simstream"],
        StreamHelpers.androidstream: ["Sources/fleetest-androidstream"],
        StreamHelpers.devicepoll: ["Sources/fleetest-devicepoll", "Sources/FTCore", "Sources/FTBridgeClient",
                                   "Sources/FTCoreSimShim"],
        ServiceGatewayWire.relayProductName: ["Sources/fleetest-services", "Sources/FTCore"],
        mcpProduct: ["Sources/fleetest-mcp", "Sources/FTCore", "Sources/FTBridgeClient", "Sources/FTFoundationModels",
                     "Sources/FTAndroid", "Sources/FTServices", "Sources/FTCoreSimShim", "Sources/FTEmulatorGrpc"],
    ]
    public static let mcpProduct = "fleetest-mcp"
    /// ビルドする順(`fleetest` が先。run に要る本体から)。**表の全製品が入っていること**はテストが固定する
    public static let buildOrder = [StreamHelpers.simstream, StreamHelpers.androidstream, StreamHelpers.devicepoll,
                             ServiceGatewayWire.relayProductName, mcpProduct]

    /// 記録に載せる `xcodebuild -version` の1行化(判定と記録で同じ式を使う)。**この式を呼ぶシェルは
    /// `DEVELOPER_DIR` を export 済みであること**(選んだ Xcode の版を読む)
    static let xcodeVersionOneLine = "xcodebuild -version 2>/dev/null | tr '\\n' ' ' | sed 's/ *$//'"

    // MARK: - ランナー上の置き場

    public static func builtRecordPath(layout: RemoteLayout) -> String { layout.toolRoot + "/" + AlignSnapshot.builtRecordRelativePath }

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

    /// `--tool-rev` で送るときの1行(コミットそのものを送る。作業ツリーは含まない)
    public static func sendLine(toolRev: String, commit: String) -> String {
        "sending \(toolRev) \(commit.prefix(7)) as is (the working tree is not included)"
    }

    // MARK: - `run --align` の判定

    public enum RunAlignDecision: Equatable, Sendable {
        /// 揃えてよい(実際に送るかは `isAlreadyAligned` が決める)
        case proceed
        /// 揃えずに止める(この機械が古い・分岐している・向きが読めない。ランナーを巻き戻さない = RR-18.3 規則1)
        case refuse(RevisionRelation)
        /// 照会そのものが読めない(ssh の失敗・行数不足)ので向きが分からない = 揃えずに止める
        case refuseUnreadable
    }

    /// 安全弁を掛けるか。**`--tool-rev` を明示したときは掛けない**(人が版を名指ししている = `remote align --tool-rev` と同じ扱い。
    /// 「直す前の版」へ揃える機能なので、手元の基点とランナーの基点を比べて止めると成り立たない)
    public static func isGuarded(requested: Bool, toolRev: String?) -> Bool { requested && toolRev == nil }

    /// `run --align` が宛先を揃えてよいか(`guarded` も含めた判定。純粋関数)。
    /// - `guarded` が false → 揃える
    /// - **照会が読めない(`probe` が nil)→ 止める**(一時的な ssh の失敗で、古い手元がランナーを巻き戻さない = RR-18.3 規則1)
    /// - 照会は読めたがクローンの HEAD が読めない(`probe.tool` が nil = クローンが無い)→ 揃える
    /// その先は `runAlignDecision`
    public static func alignDecision(guarded: Bool, localDigest: String, probe: ProbeState?,
                                     relation: (AlignSnapshot.RemoteToolState) -> RevisionRelation) -> RunAlignDecision {
        guard guarded else { return .proceed }
        guard let probe else { return .refuseUnreadable }
        return runAlignDecision(localDigest: localDigest, remote: probe.tool, relation: relation)
    }

    /// 照会が読めなかったときの止める理由(英語)
    public static let unreadableProbeAdvice = "could not read the runner's state (the ssh query failed or returned too few lines),"
        + " so it cannot tell whether this machine is behind — retry, or run `fleetest remote align <host>` to align explicitly"

    /// 要約の比較と向きの判定(`guarded` を掛けた後の本体)。
    /// - ランナーのクローンの HEAD が読めない(`remote` が nil)→ 揃える
    /// - 要約が一致 → 揃える(同じなら `isAlreadyAligned` が何も送らない。ビルド記録が欠けていれば撃ち直す)
    /// - 要約が違う → 向きで決める: `remoteBehind` / `workingTreeDiffers` は揃える、
    ///   `localBehind` / `diverged` / `unknown` は止める
    /// `relation` は要約が違うときだけ呼ぶ(git を撃つので遅延)
    public static func runAlignDecision(localDigest: String, remote: AlignSnapshot.RemoteToolState?,
                                        relation: (AlignSnapshot.RemoteToolState) -> RevisionRelation) -> RunAlignDecision {
        guard let remote else { return .proceed }
        if remote.digest == localDigest { return .proceed }
        switch relation(remote) {
        case .remoteBehind, .workingTreeDiffers: return .proceed
        case let other: return .refuse(other)
        }
    }

    // MARK: - 照会(ssh 1往復)

    /// 照会の出力の行数: `AlignSnapshot.remoteProbeCommand` の4行 + 記録の4行 + 実行ファイルの有無(yes/no) +
    /// 今の `xcodebuild -version`
    public static let probeLineCount = AlignSnapshot.probeLineCount + 6

    /// ランナーの状態を1往復で読む。出力は `probeLineCount`(10)行(`parseProbe`)。
    /// 読めない値は `-`(行数は常に10)。`developerDir` はビルドと同じ値(別に解決しない)
    public static func probeCommand(layout: RemoteLayout, developerDir: String?) -> String {
        let record = RemoteShell.quote(builtRecordPath(layout: layout))
        let binary = RemoteShell.quote(layout.binary)
        let devDir = developerDir.map { "export DEVELOPER_DIR=\(RemoteShell.quote($0)); " } ?? ""
        return devDir
            + AlignSnapshot.remoteProbeCommand(quotedToolRoot: RemoteShell.quote(layout.toolRoot)) + "; "
            + "for n in 1 2 3 4; do l=$(sed -n \"${n}p\" \(record) 2>/dev/null); printf '%s\\n' \"${l:--}\"; done; "
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

    public struct ProbeState: Equatable, Sendable {
        /// クローンが無い・git が読めないときは nil
        public let tool: AlignSnapshot.RemoteToolState?
        public let record: BuildRecord?
        public let binaryExists: Bool
        /// 今の Xcode の版(読めなければ `-`)
        public let xcodeVersion: String
        public init(tool: AlignSnapshot.RemoteToolState?, record: BuildRecord?,
                    binaryExists: Bool, xcodeVersion: String) {
            self.tool = tool
            self.record = record
            self.binaryExists = binaryExists
            self.xcodeVersion = xcodeVersion
        }
    }

    /// `probeCommand` の出力を読む。**末尾の `probeLineCount` 行で読む**(ランナーのシェル初期化ファイルが先頭へ出す
    /// 余計な行に位置をずらされない。`RemoteRunDispatcher.checkCompatibility` が末尾4行を採るのと同じ理由)。
    /// 行数が足りなければ nil(= 判定できない = 呼び手は「揃っていない」へ倒す)
    public static func parseProbe(_ output: String) -> ProbeState? {
        var all = output.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        while all.last?.isEmpty == true { all.removeLast() }
        guard all.count >= probeLineCount else { return nil }
        let lines = Array(all.suffix(probeLineCount))
        func value(_ index: Int) -> String? { lines[index].isEmpty || lines[index] == unknown ? nil : lines[index] }
        let record: BuildRecord? = {
            guard let digest = value(4), let xcode = value(6), let commit = value(7) else { return nil }
            return BuildRecord(digest: digest, developerDir: value(5), xcodeVersion: xcode, commit: commit)
        }()
        return ProbeState(tool: AlignSnapshot.parseRemoteProbe(Array(lines[0..<AlignSnapshot.probeLineCount])),
                          record: record, binaryExists: lines[8] == "yes", xcodeVersion: value(9) ?? unknown)
    }

    /// **同じなら何もしない**の判定。全部を満たすときだけ true(1つでも違えば送ってビルドする):
    /// ランナーのクローンの要約が手元と同じでビルド済み / 成功したビルドの記録が同じ要約・同じ developerDir・同じ Xcode の版 /
    /// 実行ファイルがある
    public static func isAlreadyAligned(localDigest: String, developerDir: String?, state: ProbeState) -> Bool {
        guard let tool = state.tool, tool.digest == localDigest, tool.built,
              let record = state.record, record.digest == localDigest,
              record.developerDir == developerDir,
              record.xcodeVersion == state.xcodeVersion,
              state.binaryExists else { return false }
        return true
    }

    // MARK: - ランナーでのビルド(fm-align の `--build-command`。`/bin/sh -c` で走る)

    /// 送ったコミットを checkout してビルドし、全部成功したら記録を書く。**全製品をこの中(= dispatch.lock の下)で
    /// ビルドする**(`swift build` も重い負荷で、ロックの外へ出すと直後の run と CPU を取り合い、SwiftPM が
    /// `.build/debug` のリンクを作り直す瞬間に run の exec が ENOENT で落ちる)。
    /// - `fleetest` は必ずビルドする(run に要る。閉包が大きく省いても得が小さい)
    /// - それ以外(`productSourceClosure`)は **記録があり・developerDir と Xcode の版が記録と同じ・前回のコミットから
    ///   閉包のディレクトリと Package.swift / Package.resolved が無変更・実行ファイルがある** ときだけ省く
    ///   (1つでも欠けたらビルド)。差分が引けない(前回のコミットがランナーに無い)ときも `git diff --quiet` は
    ///   非0 = ビルドに倒れる
    public static func buildScript(layout: RemoteLayout, revision: String, digest: String,
                                   developerDir: String?) -> String {
        let record = RemoteShell.quote(builtRecordPath(layout: layout))
        let skip = "[ -n \"$ft_prev_rev\" ] && [ \"$ft_prev_dev\" = \"$ft_dev\" ] && [ \"$ft_prev_xc\" = \"$ft_xc\" ] "
            + "&& [ -x \"$ft_root/.build/debug/$ft_p\" ] "
            + "&& git diff --quiet \"$ft_prev_rev\" \"$ft_rev\" -- \"$@\" Package.swift Package.resolved"
        let function = "ft_build() { ft_p=$1; shift; if \(skip); then "
            + "echo \"skipping $ft_p (unchanged since the last successful build)\"; else swift build --product \"$ft_p\"; fi; }"
        // 閉包の表に無い製品は省かずビルドする(空のディレクトリ集合で「無変更」と読まない)
        let builds = buildOrder.map { product -> String in
            guard let closure = productSourceClosure[product], !closure.isEmpty else {
                return "swift build --product \(RemoteShell.quote(product))"
            }
            return "ft_build \(RemoteShell.quote(product)) \(closure.map(RemoteShell.quote).joined(separator: " "))"
        }
        return "ft_root=\(RemoteShell.quote(layout.toolRoot)); ft_rec=\(record); "
            + "ft_dev=\(RemoteShell.quote(developerDir ?? unknown)); ft_rev=\(RemoteShell.quote(revision)); "
            + "ft_xc=$(\(xcodeVersionOneLine)); ft_xc=\"${ft_xc:--}\"; "
            + "ft_prev_dev=$(sed -n 2p \"$ft_rec\" 2>/dev/null); ft_prev_xc=$(sed -n 3p \"$ft_rec\" 2>/dev/null); "
            + "ft_prev_rev=$(sed -n 4p \"$ft_rec\" 2>/dev/null); "
            + "rm -f \"$ft_rec\" && "
            + "cd \"$ft_root\" && git checkout -q --detach \"$ft_rev\" && \(function) && "
            + "swift build --product fleetest && "
            + builds.joined(separator: " && ") + " && "
            + "mkdir -p \"$ft_root/.fleetest\" && "
            + "printf '%s\\n%s\\n%s\\n%s\\n' \(RemoteShell.quote(digest)) \"$ft_dev\" \"$ft_xc\" \"$ft_rev\" > \"$ft_rec\""
    }
}
