// AlignSnapshot.swift
// align の直送(手元の作業ツリーを1つのコミットにしてランナーのクローンへ git push)と、
// ディスパッチの照合に使う「ツールの中身の要約」。**手元とランナーで同じ規則を通す**(片方だけ変えない。
// 等価性は AlignSnapshotTests が同じツリーに両方を当てて固定する)。
//
// 要約 = `git ls-tree <tree>` から TestProjects の行を除いた列の `git hash-object`。
// コミットの SHA ではなく中身で比べる —— 未コミットの変更を送った回も、同じ中身を後からコミットした回も
// 同じ値になり、「SHA は同じで中身が違う」(未コミットの変更が届かないまま緑)を作らない。

import FTCore
import Foundation

public enum AlignSnapshot {
    /// スナップショットのコミットの1行目。ランナーの照会はこれで「基点 = HEAD^1」を見分ける
    public static let marker = "fleetest-align-snapshot"
    /// 送り先の ref。ブランチにしない(ランナーのクローンは detached HEAD。checkout 中のブランチへの push は拒否される)
    public static let pushRef = "refs/fleetest/align"
    /// 要約から外すトップレベルの名前。TestProjects/<P> は run のたびに rsync で届く(RR-13)ので、
    /// ここを含めるとシナリオを直しただけでディスパッチが止まる
    public static let excludedTopLevel = "TestProjects"
    /// コミットの作者・日時を固定する名前(同じ中身から同じ SHA = align.sh が全機へ並列に作っても揃う)
    static let authorName = "fleetest"
    static let authorEmail = "fleetest@localhost"

    // MARK: - 純粋部分

    /// `git ls-tree` の出力から要約の入力を作る。**ランナー側の `remoteProbeCommand` の awk と同じバイト列**
    /// (残した行 + 改行。ls-tree の行は `<mode> <type> <sha>\t<name>`)
    public static func digestInput(lsTree: String) -> String {
        lsTree.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { line in
                guard let tab = line.firstIndex(of: "\t") else { return true }
                return line[line.index(after: tab)...] != Substring(excludedTopLevel)
            }
            .map { $0 + "\n" }
            .joined()
    }

    /// スナップショットのコミットメッセージ。issuer は本文の `issuer: ` 行(ランナーの照会が読む)
    public static func commitMessage(issuer: String) -> String {
        "\(marker)\n\nissuer: \(issuer)\n"
    }

    /// ランナーの状態の照会。`toolRoot` は呼び手が引用済みの式で渡す(RemoteStatusProbe は `$HOME` を
    /// 遅延展開させるため二重引用符で包む)。出力は4行: HEAD / 要約 / 基点 / スナップショットの issuer。
    /// 読めない値は `-`(行数は常に4 = 呼び手が固定位置で読める)
    public static func remoteProbeCommand(quotedToolRoot r: String) -> String {
        "if h=$(git -C \(r) rev-parse HEAD 2>/dev/null); then echo \"$h\"; "
            + "git -C \(r) ls-tree HEAD | awk -F'\\t' '$2 != \"\(excludedTopLevel)\"' | git hash-object --stdin "
            + "2>/dev/null || echo -; "
            + "if [ \"$(git -C \(r) log -1 --format=%s HEAD 2>/dev/null)\" = \(marker) ]; then "
            + "git -C \(r) rev-parse HEAD^1 2>/dev/null || echo -; "
            + "i=$(git -C \(r) log -1 --format=%b HEAD 2>/dev/null | sed -n 's/^issuer: //p' | head -1); "
            + "echo \"${i:--}\"; "
            + "else echo \"$h\"; echo -; fi; "
            + "else echo -; echo -; echo -; echo -; fi"
    }

    /// `remoteProbeCommand` の4行を読む。HEAD が `-` なら nil(クローンが無い・git が読めない)
    public static func parseRemoteProbe(_ lines: [String]) -> RemoteToolState? {
        let values = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        guard values.count >= 4 else { return nil }
        func value(_ index: Int) -> String? { values[index] == "-" || values[index].isEmpty ? nil : values[index] }
        guard let head = value(0) else { return nil }
        return RemoteToolState(head: head, digest: value(1), base: value(2) ?? head, snapshotIssuer: value(3))
    }

    public struct RemoteToolState: Equatable, Sendable {
        /// ランナーのクローンの HEAD(スナップショットならそのコミット)
        public let head: String
        /// ツールの中身の要約(読めなければ nil = 照合は不一致として止める)
        public let digest: String?
        /// 向きの判定に使うコミット(スナップショットなら HEAD^1 = 作った人の HEAD、そうでなければ HEAD)
        public let base: String
        /// スナップショットを置いた発行者(スナップショットでなければ nil)
        public let snapshotIssuer: String?

        public init(head: String, digest: String?, base: String, snapshotIssuer: String?) {
            self.head = head
            self.digest = digest
            self.base = base
            self.snapshotIssuer = snapshotIssuer
        }
    }

    // MARK: - 手元の I/O(git を撃つ。**終了コードを見る** = 失敗の出力を値にしない)

    public struct LocalTree: Equatable, Sendable {
        /// 手元の HEAD
        public let head: String
        /// 作業ツリー(未追跡を含む・.gitignore は効く)のツリー
        public let tree: String
        /// HEAD のツリーと同じか(同じならスナップショットを作らず HEAD をそのまま送る)
        public let isClean: Bool
        /// 要約
        public let digest: String
    }

    public enum SnapshotError: Error, LocalizedError {
        case git(String)
        public var errorDescription: String? {
            if case .git(let detail) = self { return detail }
            return nil
        }
    }

    /// 作業ツリーのツリーと要約を求める。**本物のインデックスもブランチも触らない**(一時インデックスへ
    /// 本物をコピーしてから `add -A` する。コピーするのは stat の控えを使わせて速くするため)。
    /// 書くのはオブジェクトだけ(参照の無いオブジェクトは git gc が後で消す)
    public static func localTree(repoRoot: URL) throws -> LocalTree {
        let head = try git(repoRoot, ["rev-parse", "HEAD"])
        let headTree = try git(repoRoot, ["rev-parse", "HEAD^{tree}"])
        let indexPath = try git(repoRoot, ["rev-parse", "--path-format=absolute", "--git-path", "index"])
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-align-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        if FileManager.default.fileExists(atPath: indexPath) {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: indexPath), to: temporary)
        }
        let env = ["GIT_INDEX_FILE=\(temporary.path)"]
        _ = try git(repoRoot, ["add", "-A"], env: env)
        let tree = try git(repoRoot, ["write-tree"], env: env)
        return LocalTree(head: head, tree: tree, isClean: tree == headTree,
                         digest: try digest(repoRoot: repoRoot, tree: tree))
    }

    /// ツリーの要約(ランナーの `remoteProbeCommand` と同じ規則)
    public static func digest(repoRoot: URL, tree: String) throws -> String {
        let listing = try git(repoRoot, ["ls-tree", tree])
        return try git(repoRoot, ["hash-object", "--stdin"], stdin: Data(digestInput(lsTree: listing + "\n").utf8))
    }

    /// 送るコミット。きれいなら HEAD そのもの、汚れていれば HEAD を親にしたスナップショット
    /// (作者・日時を固定 = 同じ中身・同じ HEAD・同じ issuer から同じ SHA)
    public static func commitToSend(repoRoot: URL, local: LocalTree, issuer: String) throws -> String {
        if local.isClean { return local.head }
        let date = try git(repoRoot, ["log", "-1", "--format=%cI", "HEAD"])
        let env = ["GIT_AUTHOR_NAME=\(authorName)", "GIT_AUTHOR_EMAIL=\(authorEmail)", "GIT_AUTHOR_DATE=\(date)",
                   "GIT_COMMITTER_NAME=\(authorName)", "GIT_COMMITTER_EMAIL=\(authorEmail)",
                   "GIT_COMMITTER_DATE=\(date)"]
        return try git(repoRoot, ["commit-tree", local.tree, "-p", local.head, "-F", "-"], env: env,
                       stdin: Data(commitMessage(issuer: issuer).utf8))
    }

    /// 送る未追跡ファイル(.gitignore で外れない物)の件数と合計バイト。表示用の事実(閾値は置かない)
    public static func untrackedSummary(repoRoot: URL) throws -> (count: Int, bytes: Int64) {
        let listing = try git(repoRoot, ["ls-files", "-z", "-o", "--exclude-standard"])
        var count = 0
        var bytes: Int64 = 0
        for relative in listing.split(separator: "\0") where !relative.isEmpty {
            count += 1
            let path = repoRoot.appendingPathComponent(String(relative)).path
            if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber {
                bytes += size.int64Value
            }
        }
        return (count, bytes)
    }

    private static func git(_ repoRoot: URL, _ args: [String], env: [String] = [], stdin: Data? = nil) throws -> String {
        let argv = env.isEmpty ? ["git", "-C", repoRoot.path] + args
            : ["/usr/bin/env"] + env + ["git", "-C", repoRoot.path] + args
        let result: (status: Int32, data: Data)
        if let stdin {
            // runData は stdin を受けないので run で撃つ(hash-object / commit-tree の出力は SHA 1行で stderr は混ざらない)
            let merged = try Shell.run(argv, stdin: stdin)
            result = (merged.status, Data(merged.output.utf8))
        } else {
            result = try Shell.runData(argv)
        }
        guard result.status == 0 else {
            throw SnapshotError.git("git \(args.first ?? "") failed (exit \(result.status)): "
                + (String(data: result.data, encoding: .utf8) ?? "").suffix(300))
        }
        return (String(data: result.data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
