// RemoteAlignPrebuilt.swift
// `remote align` が手元のビルド済みの製品を送る選別の I/O(判定は Sources/FTRemote/AlignPrebuilt.swift・取り込みは
// `RemoteAlignPlan.buildScript` の `ft_install`)。呼び手は RemoteAlign.swift の `runRemoteAlignment` だけ。

import FTCore
import FTRemote
import Foundation

/// 送る製品のファイル(ヘルパー自身の `fleetest` は含めない)と、ビルドのスクリプトへ渡す計画
struct PrebuiltSelection {
    let plan: AlignPrebuilt.Plan
    let files: [URL]
    static let none = PrebuiltSelection(plan: .none, files: [])
}

/// 全製品(`fleetest` + `buildOrder`)を判定する。**ヘルパーが `fleetest` 以外の名前なら何も送らない**
/// (送り先のファイル名がヘルパーの名前に決まるため。CLI では起きない)。手元の製品はヘルパーと同じディレクトリ
/// (= このクローンの `.build/debug` の実体)に並ぶ
func selectPrebuiltProducts(prepared: AlignPrepared, probe: RemoteAlignPlan.ProbeState?, executable: URL) -> PrebuiltSelection {
    guard executable.lastPathComponent == "fleetest" else { return .none }
    let productsDirectory = executable.deletingLastPathComponent()
    let clonePrefix = prepared.repoRoot.resolvingSymlinksInPath().path + "/.build/"
    let builtInThisClone = executable.resolvingSymlinksInPath().path.hasPrefix(clonePrefix)
    let localToolchain = AlignPrebuilt.localToolchainLine(fingerprint: ToolchainFingerprint.current())
    let runnerToolchain = probe.map(\.xcodeVersion).flatMap { $0 == RemoteAlignPlan.unknown ? nil : $0 }
    var decisions: [String: AlignPrebuilt.Decision] = [:]
    var files: [URL] = []
    for product in ["fleetest"] + RemoteAlignPlan.buildOrder {
        let binary = product == "fleetest" ? executable : productsDirectory.appendingPathComponent(product)
        let decision = AlignPrebuilt.decide(.init(
            fromWorkingTree: prepared.fromWorkingTree,
            builtInThisClone: builtInThisClone,
            binaryFresh: AlignPrebuilt.isFresh(binary: binary, repoRoot: prepared.repoRoot, product: product),
            localToolchainReadable: localToolchain != nil,
            runnerToolchainIdentical: runnerToolchain.flatMap { remote in localToolchain.map { $0 == remote } },
            unchangedSinceLastBuild: product != "fleetest"
                && runnerWillSkip(product: product, prepared: prepared, probe: probe)))
        decisions[product] = decision
        if decision == .ship, product != "fleetest" { files.append(binary) }
    }
    let plan = AlignPrebuilt.plan(decisions: decisions, localToolchain: localToolchain ?? "")
    return PrebuiltSelection(plan: plan, files: files)
}

/// ランナーの `ft_build` が「無変更」で省くと見込めるか(同じ記録の Xcode・developerDir で、前回のコミットから閉包が無変更)。
/// **予測であって決定ではない**(実行ファイルの有無はランナーでしか分からない。外れても送り損か、ランナーでビルドになるだけ)。
/// 差分が引けない(前回のコミットが手元に無い等)ときは false = 送る
private func runnerWillSkip(product: String, prepared: AlignPrepared, probe: RemoteAlignPlan.ProbeState?) -> Bool {
    guard let probe, let record = probe.record, probe.xcodeVersion != RemoteAlignPlan.unknown,
          record.developerDir == prepared.developerDir, record.xcodeVersion == probe.xcodeVersion,
          let closure = RemoteAlignPlan.productSourceClosure[product] else { return false }
    let paths = closure + ["Package.swift", "Package.resolved"]
    guard let diff = try? Shell.run(["/usr/bin/git", "-C", prepared.repoRoot.path, "diff", "--quiet",
                                     record.commit, prepared.commit, "--"] + paths) else { return false }
    return diff.status == 0
}
