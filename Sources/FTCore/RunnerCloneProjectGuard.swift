// RunnerCloneProjectGuard.swift
// ランナー機のツールのクローン(`<base>/fleetest`)の中で、そのクローン自身の TestProjects を使って
// デバイスに触る操作を断る判定(純粋部分)。I/O は Sources/fleetest/RunnerCloneProjectCheck.swift。
//
// 背景: align は発行側の作業ツリーをそのまま送るので、クローンの `TestProjects/*/profiles/runs/*.json` は
// **発行側の視点**(発行側のデバイス = "local"・ランナー自身のデバイス = エイリアス)。ランナーは自分のエイリアスを
// 知らない(エイリアスをリモートへ出さない = RR-0)ので、ここを直に読むと発行側のデバイスを自分のものと読んで
// 起動・消去する。正しい経路は `<base>/users/<issuer>/work/TestProjects/<P>` のランナー視点のコピー
// (RunnerProfileTransfer.localizeAndUpload)を読む。
// 印は align が書く `.fleetest/runner-clone.json`(エイリアスを含めない。`.fleetest/` は gitignore なので align で消えない)。

import Foundation

public enum RunnerCloneProjectGuard {

    /// ツールのルートからの印の相対パス
    public static let markerRelativePath = ".fleetest/runner-clone.json"

    /// 印の中身。**エイリアス・ホスト名を入れない**(`RunnerCloneProjectGuardTests` が固定)
    public static let markerContent = Data("{\"kind\":\"runner-clone\"}\n".utf8)

    /// `projectRoot` が `<toolRoot>/TestProjects/` の中か。symlink は解決して比べる
    /// (`/var` と `/private/var` の食い違いで work のコピーをクローン内と読まない・逆も)
    public static func isInsideCloneProjects(projectRoot: URL, toolRoot: URL) -> Bool {
        let projects = toolRoot.appendingPathComponent("TestProjects").resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let project = projectRoot.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return project.count > projects.count && Array(project.prefix(projects.count)) == projects
    }

    /// 断る文言(nil = 通す)。**全部そろったときだけ断る**:
    /// 印がある / プロジェクトがクローン自身の TestProjects の中 / 機械の注記がある /
    /// 呼び手が台の選び方を明示していない —— `--device-machine <機械>` はランナー視点の正しい選び方、
    /// `run` の `--runner local` は「"local" の項目をこの機械の台として使う」明示(Scripts/e2ex.sh・e2ey.sh の `--on` が
    /// 名前だけで指す -01〜-08 をランナーの同名の台で回す運用。断ると通常の分担が止まる)
    public static func refusal(hasMarker: Bool, projectInsideClone: Bool, machineAnnotated: Bool,
                               explicitMachineChoice: Bool) -> String? {
        guard hasMarker, projectInsideClone, machineAnnotated, !explicitMachineChoice else { return nil }
        return "this is a runner clone: the run profiles in its TestProjects are written from the issuer's view"
            + " (the issuer's devices are \"local\"), so the devices they name are not this machine's."
            + " Run it from the issuer with `--runner <machine>`"
            + " (or `fleetest remote exec <machine> -- ... --device-machine <machine>`)"
            + " instead of running it inside the runner clone; pass `--runner local` only when the profile's"
            + " \"local\" devices are meant to be this machine's own"
    }
}
