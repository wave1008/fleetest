// RunPreparation.swift
// `fleetest run` と `fleetest api run` のビルド後の段を1箇所に持つ: シナリオの一覧(OCR のモデルのコンパイルの要否)→
// FM の常駐プロセスの用意 → 一覧が空なら断る → 名指しの照合と重なりの注記。
// 呼び手の差分は引数だけ: 注記の出し口(run は stdout・api run は stderr = stdout は NDJSON 専用)・一覧の失敗時の記録
// (run だけ JUnit を書く)・一覧の直後に呼び手が言うこと(api run の @RunHooks の注記)。
// この後(@Deleted / @Draft・--folder・--failed・選択が空のときの扱い・配置の検査)は2つで意味が違うので呼び手に残す。
// 順序(一覧 < FM の常駐プロセス)は FMServeTests が、OCR のコンパイルの条件は OCRModelCompileWiringTests が、
// 重なりの注記は CollapsedSelectionNoticeWiringTests がこのファイルの走査で固定する

import ArgumentParser
import Foundation
import FTCore

enum RunPreparation {

    struct Listing {
        let all: [ScenarioInfo]
        /// `@RunHooks` のクラス名(beforeRun / afterRun。RR-8.4)
        let runHooksClass: String?
        let selected: [ScenarioInfo]
    }

    /// `fm` / `ocrTextVisibilityCheck` はこの run の実効値(プロファイルがあればその値・無ければプロファイル無しの設定)
    static func listAndSelect(
        project: TestProject, scenarios: [String], dryRun: Bool,
        fm: FMConfig, ocrTextVisibilityCheck: Bool,
        log: (String) -> Void,
        onListFailure: (Error) -> Void,
        afterListing: (_ runHooksClass: String?) -> Void
    ) async throws -> Listing {
        let listing: ScenarioListing
        do {
            listing = try ScenarioHost.listForRun(
                project: project, dryRun: dryRun,
                compilesOCR: ScenarioHost.ocrCompileNeeded(
                    fmTextVisibilityCheck: fm.fmTextVisibilityCheck,
                    ocrTextVisibilityCheck: ocrTextVisibilityCheck))
        } catch {
            onListFailure(error)
            throw error
        }
        afterListing(listing.runHooksClass)
        // FM の常駐プロセス(画像を伴う FM の呼び出しを1つのプロセスに集める。FTCore/FMServe.swift 冒頭)。
        // シナリオのプロセスを起こす前に用意する(子の環境とサンドボックスの許可がソケットのパスを読む)。
        // 出し口は両方とも stderr(api run の stdout は NDJSON 専用)
        if !dryRun, FMServeHost.needed(fmTextVisibilityCheck: fm.fmTextVisibilityCheck,
                                       screenLooksLike: fm.screenLooksLike) {
            await FMServeHost.ensureRunning { ConsoleOut.err($0) }
        }
        let all = listing.scenarios
        guard !all.isEmpty else {
            throw ValidationError(
                "no scenarios (add a @TestClass under TestProjects/\(project.name)/scenarios/)")
        }
        // scenariosDir を渡す = 隔離フォルダ(_disabled)にあるクラスの名指しを、そこにあると言って断る
        let resolution = try ScenarioSelection.resolveReportingCollapsed(scenarios, from: all,
                                                                         scenariosDir: project.scenariosDir)
        // 重なった指定を1回に畳んだことは言う(NDJSON の契約には足さない)
        if let notice = ScenarioSelection.collapsedNotice(resolution.collapsed) { log(notice) }
        return Listing(all: all, runHooksClass: listing.runHooksClass, selected: resolution.selected)
    }
}
