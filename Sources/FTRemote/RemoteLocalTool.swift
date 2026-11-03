// RemoteLocalTool.swift
// ディスパッチの照合に使う「手元のツールの同一性」を求める**唯一の関数**。
// `RemoteRunDispatcher.checkCompatibility` / `remote status` / `api remote-compat` が通る
// (別々に書くと、同じ `--tool-rev` で経路ごとに照合の手元の値が食い違う)。

import Foundation

extension RemoteCompat {
    /// `toolRev` が nil なら作業ツリー(未コミット・未追跡を含む)から、あれば `<toolRev>` のコミットのツリーから
    /// 要約を求める。後者の `head`(向きの判定の手元の基点)はそのコミット・`isClean` は true(比べる中身はコミットそのもの)。
    /// git が失敗したら throw(呼び手は fail-closed で止める)
    public static func localTool(repoRoot: URL, toolRev: String?) throws -> LocalTool {
        if let toolRev {
            let revision = try AlignSnapshot.revisionTree(repoRoot: repoRoot, rev: toolRev)
            return LocalTool(head: revision.commit, digest: revision.digest, isClean: true)
        }
        let tree = try AlignSnapshot.localTree(repoRoot: repoRoot)
        return LocalTool(head: tree.head, digest: tree.digest, isClean: tree.isClean)
    }
}
