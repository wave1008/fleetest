// ScenarioHost+Prebuilt.swift
// 親(別の機械)がビルドして送ってきたシナリオ実行バイナリを使う口。ランナーの子だけが入れる(`--prebuilt-scenarios`)。
// **実行バイナリの場所を決めるのは `runnerURL` の1箇所**で、ここの登録を最初に見る。

import Foundation

extension ScenarioHost {
    struct PrebuiltRunner: Sendable {
        let binary: URL
        /// ビルドした機械のパッケージルート(`#filePath` の接頭辞。子へは `FT_SCENARIO_ORIGIN_ROOT` で渡す)
        let originRoot: String?
        /// この機械のツールのルート(子へ `FT_TOOL_ROOT` で渡す)。送られたバイナリは置き場所から辿ってもツールに着かず
        /// (`RepoRoot.find` の 2)、焼かれた `#filePath` はビルドした機械のパス(3)= 渡さないとシナリオが「repo root detection failed」で全部赤
        let toolRoot: String?
    }

    /// 製品名 → 送られたバイナリ。**製品名で引く** = 別のプロジェクトのバイナリを返さない
    static let prebuiltRunners = LockedValue([String: PrebuiltRunner]())

    static func prebuiltRunner(for project: TestProject) -> PrebuiltRunner? {
        prebuiltRunners.value[project.productName]
    }

    /// 子の環境へ載せる origin(送られたバイナリが無ければ nil = 環境に残さない)
    static var prebuiltOriginRoot: String? {
        prebuiltRunners.value.values.compactMap(\.originRoot).first
    }

    /// 子の環境へ載せるツールのルート(送られたバイナリが無ければ nil = 今までどおり環境を変えない)
    static var prebuiltToolRoot: String? {
        prebuiltRunners.value.values.compactMap(\.toolRoot).first
    }

    /// 送られたバイナリを受け入れる。**使えなければ登録せず false**(呼び手は今までどおりビルドする)。
    /// 製品名と一致するファイル名・実行可能・サイズ非0 だけ通す。署名の Identifier は親のビルド後の固定と同じく揃える
    @discardableResult
    public static func usePrebuilt(project: TestProject, binary: URL, originRoot: String?, toolRoot: String?,
                                   log: ((String) -> Void)?) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: binary.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard binary.lastPathComponent == project.productName else {
            log?("→ The prebuilt scenarios from the parent are for another product — building here")
            return false
        }
        guard FileManager.default.isExecutableFile(atPath: binary.path), size > 0 else {
            log?("→ The prebuilt scenarios from the parent are missing or not executable — building here")
            return false
        }
        prebuiltRunners.withLock { $0[project.productName] = PrebuiltRunner(binary: binary, originRoot: originRoot, toolRoot: toolRoot) }
        pinSigningIdentifier(binary: binary, productName: project.productName, log: log)
        log?("→ Using the prebuilt scenarios sent by the parent (\(size / 1_000_000) MB)")
        return true
    }

    /// 親側: 手元の製品が新しいときのバイナリ(`build` がビルドを省く条件と同じ。省く判定を2か所に書かない)。
    /// 並行の run-file の置き場を消さないよう掃除は呼ばない(残っていれば指紋が食い違い、新しくない扱いで送らない)
    public static func freshBuiltBinary(project: TestProject) -> URL? {
        guard let root = packageRoot(),
              let fingerprint = BuildFingerprint.snapshot(repoRoot: root, scenariosDir: project.scenariosDir)?.digest,
              !buildNeeded(fingerprint: fingerprint, project: project, root: root) else { return nil }
        return try? runnerURL(project: project)
    }
}
