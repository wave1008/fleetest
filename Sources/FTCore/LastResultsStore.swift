// LastResultsStore.swift
// シナリオの直近実行結果を1ファイル/シナリオで記録する(`fleetest run --failed` の絞り込み用)。
// ファイルはシナリオIDそのもの(拡張子なし・日本語可)で内容は "passed"/"failed"。
// 異なるシナリオは別ファイルなのでロック不要。同一シナリオの同時実行は元々非対応
// (1シナリオ1プロセスの原則。ScenarioHost.run 参照)。
//
// **記録は (project, profile) 単位**。1プロジェクトの記録を1つに畳むと、
// 別プロファイル/別プラットフォームの緑が別プロファイルの赤を上書きし、`--failed` が
// 拾えなくなる(vscode-fleetest 側は lastResults.ts が「どれか1プロファイルでも failed なら
// failed」として複数プロファイル分を1つのアイコンへ畳む。両方読む・書く側の規則を合わせること)。

import Foundation

public enum LastResultsStore {

    /// profile-less な run(`--profile` 無し)の専用区分。プロファイル名はファイル名の一部として
    /// 使われるため、実在のプロファイル名と衝突しないよう予約語にする("_" 始まりはプロファイル名
    /// のバリデーションでは特に禁止されていないが、実運用で使われることはまず無い)
    public static let noProfileKey = "_no-profile"

    /// 受け手パッケージ直下 .fleetest/last-results/<projectName>/<profile>/(packageRoot 優先、
    /// 無ければ rootURL から2階層遡る)。TestProjects/ を持つ側が正で、ツール本体の
    /// RepoRoot.find()(ブリッジ資産の在り処)とは別物。**`profile` は必須引数**
    /// (nil は「profile-less」の意味で `noProfileKey` へ畳む。既定値を置くと呼び出し忘れが
    /// コンパイルで見えなくなる)
    public static func stateDir(project: TestProject, profile: String?) -> URL {
        let root = ScenarioHost.packageRoot() ?? project.rootURL
            .deletingLastPathComponent().deletingLastPathComponent()
        return root.appendingPathComponent(".fleetest/last-results")
            .appendingPathComponent(project.name)
            .appendingPathComponent(profile ?? noProfileKey)
    }

    /// バリアントごとの単位の記録の置き場(`<profile>/variants/<variant>/<ID>`)。ID の記録(`<profile>/<ID>`)と同じ階層に
    /// ディレクトリとして並ぶので、ID の記録を読む側は**ファイルだけ**を読む(拡張の `lastResults.ts` も同じ)
    static let variantsDirName = "variants"

    /// 単位の直近結果を記録する(best-effort)。失敗しても呼び出し側の実行結果には影響させない。
    /// - runID: 単位の記録の印(同じ run の中で同じ単位が複数の端末に回った = `--broadcast` のとき、後の passed で failed を
    ///   上書きしない)。nil は印なし(後勝ち)
    /// - declaredVariants: その run が宣言したバリアント(ID の記録の集約の母集団。この単位のバリアントは必ず含める)
    public static func record(project: TestProject, unit: ScenarioUnitKey, passed: Bool, profile: String?,
                              runID: String?, declaredVariants: [String]) {
        record(stateDir: stateDir(project: project, profile: profile), unit: unit, passed: passed,
               runID: runID, declaredVariants: declaredVariants)
    }

    static func record(stateDir: URL, unit: ScenarioUnitKey, passed: Bool,
                       runID: String?, declaredVariants: [String]) {
        let fm = FileManager.default
        guard let variant = unit.variant else {
            // バリアントの無い run は今のまま(ID の記録だけ・内容は passed / failed)
            try? fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
            try? (passed ? "passed" : "failed").write(
                to: stateDir.appendingPathComponent(unit.id), atomically: true, encoding: .utf8)
            return
        }
        let dir = variantDir(stateDir: stateDir, variant: variant)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(unit.id)
        let stamp = runID.map { "\n" + $0 } ?? ""
        let previous = try? String(contentsOf: file, encoding: .utf8)
        // 同じ run の中の failed は passed で上書きしない
        let keepFailed = passed && runID != nil && previous == "failed" + stamp
        if !keepFailed {
            try? ((passed ? "passed" : "failed") + stamp).write(to: file, atomically: true, encoding: .utf8)
        }
        aggregate(stateDir: stateDir, id: unit.id, variants: declaredVariants + [variant])
    }

    private static func variantDir(stateDir: URL, variant: String) -> URL {
        stateDir.appendingPathComponent(variantsDirName).appendingPathComponent(variant)
    }

    /// 単位の記録の1行目(passed / failed)。無ければ nil
    private static func unitState(_ file: URL) -> String? {
        (try? String(contentsOf: file, encoding: .utf8))?
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
    }

    /// ID の記録を、宣言のバリアントの単位の記録から作り直す(1つでも failed なら failed)。単位を書くたびに呼ぶ
    private static func aggregate(stateDir: URL, id: String, variants: [String]) {
        var seen: Set<String> = [], failed = false, any = false
        for v in variants where seen.insert(v).inserted {
            guard let state = unitState(variantDir(stateDir: stateDir, variant: v).appendingPathComponent(id)) else { continue }
            any = true
            if state == "failed" { failed = true }
        }
        guard any else { return }
        try? (failed ? "failed" : "passed").write(
            to: stateDir.appendingPathComponent(id), atomically: true, encoding: .utf8)
    }

    /// 直近失敗した単位の集合(この `(project, profile)` の記録だけ)。ディレクトリが無ければ空集合。
    /// **declaredVariants が空 = バリアントの無いプロファイル**: ID の記録を variant nil の単位として返す(`variants/` の下は残っても読まない)。
    /// 空でなければ宣言のバリアントの単位の記録だけを読む(ID の記録はその集約なので読まない)
    public static func failedIDs(project: TestProject, profile: String?, declaredVariants: [String]) -> Set<ScenarioUnitKey> {
        failedIDs(stateDir: stateDir(project: project, profile: profile), declaredVariants: declaredVariants)
    }

    /// 記録のあるシナリオ数(passed / failed の別なく)。`--failed` が空のとき「全部緑」と
    /// 「まだ1本も走っていない」を言い分けるための材料
    public static func recordedCount(project: TestProject, profile: String?) -> Int {
        recordedCount(stateDir: stateDir(project: project, profile: profile))
    }

    static func recordedCount(stateDir: URL) -> Int {
        recordFiles(stateDir: stateDir).count
    }

    /// `--failed` の対象が空だったときの発話(`run` の単機経路・フリート経路で共有)。
    /// **空は「直近失敗 ∩ 選んだ範囲(--scenario / --folder)」** —— 直近失敗が範囲の外にだけあるときに
    /// 「全部緑」と言うと誤る(failedCount = 範囲で絞る前の直近失敗の数)
    /// - hasSelection: `--scenario` / `--folder` で範囲を絞ったか。絞っていないのに「範囲の外」とは言わない
    /// - staleCount: 失敗の記録のうち今のプロジェクトに無いシナリオの数(`failedCount` には含めない)
    public static func nothingFailedMessage(recordedCount: Int, failedCount: Int,
                                            hasSelection: Bool = true, staleCount: Int = 0) -> String {
        if failedCount > 0 {
            return hasSelection
                ? "None of the selected scenarios failed last time (\(failedCount) scenario(s) outside this selection did)"
                : "None of the scenarios that failed last time can run now (\(failedCount) are marked @Deleted or @Draft)"
        }
        if staleCount > 0 {
            return "No scenarios in this project failed last time (\(staleCount) recorded failure(s) belong to scenarios that no longer exist here)"
        }
        return recordedCount == 0
            ? "No results recorded yet for this project/profile (nothing has run), so there is nothing to re-run"
            : "No scenarios failed last time (every recorded scenario passed)"
    }

    /// ID の記録(ファイルだけ。`variants/` のディレクトリは ID ではない)
    private static func recordFiles(stateDir: URL) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: stateDir.path) else { return [] }
        return names.filter { name in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: stateDir.appendingPathComponent(name).path, isDirectory: &isDir)
                && !isDir.boolValue
        }
    }

    static func failedIDs(stateDir: URL, declaredVariants: [String]) -> Set<ScenarioUnitKey> {
        var result: Set<ScenarioUnitKey> = []
        if declaredVariants.isEmpty {
            for name in recordFiles(stateDir: stateDir) where unitState(stateDir.appendingPathComponent(name)) == "failed" {
                result.insert(ScenarioUnitKey(id: name, variant: nil))
            }
            return result
        }
        for v in Set(declaredVariants) {
            let dir = variantDir(stateDir: stateDir, variant: v)
            for name in recordFiles(stateDir: dir) where unitState(dir.appendingPathComponent(name)) == "failed" {
                result.insert(ScenarioUnitKey(id: name, variant: v))
            }
        }
        return result
    }
}
