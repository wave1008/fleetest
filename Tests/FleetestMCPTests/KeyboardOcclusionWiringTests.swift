// **MCP と DSL の全呼び出し元が KeyboardOcclusion を通ること**の配線ゲート。
// 型を keyboardFrame: FTRect? から keyboardOcclusion: KeyboardOcclusion へ変えるだけでは、
// 呼び出し側が `.none` を渡す・毎回新しい空の値を作るといった「実質何も除外しない」変異を
// コンパイラは止められない。ここは各ファイルのソースを読んで
// `KeyboardOcclusion.resolve(reported:` が実際にそのスナップショットから作られていることまで見る。

import XCTest
import FTCore
@testable import fleetest_mcp

final class KeyboardOcclusionWiringTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/FleetestMCPTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // リポジトリ直下

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent("Sources/" + relativePath),
                    encoding: .utf8)
    }

    /// 空白と改行を落とした形で照合する。**引数の改行位置に依存させない** ——
    /// 素のリテラル照合だと `resolve(\n    reported:` のような普通の折り返しで落ち、
    /// 配線ではなく整形を検査するテストになる(実際に落ちた)
    private func compact(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// Sources 全体の .swift(相対パス → コメントを落とした本文)
    private func allSources() throws -> [String: String] {
        let root = Self.repoRoot.appendingPathComponent("Sources")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var result: [String: String] = [:]
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let noBlocks = text.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
            result[String(url.path.dropFirst(root.path.count + 1))] = noBlocks
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
                .joined(separator: "\n")
        }
        return result
    }

    private func matches(_ regex: String, in text: String) -> Int {
        (try? NSRegularExpression(pattern: regex)).map { $0.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) } ?? 0
    }

    /// `KeyboardOcclusion.resolve(reported:` を呼ぶファイル。**ft_double_tap(MCPServer+GesturesTools)も同じ被覆にする契約なので
    /// 同列**。新しい呼び出し元はここへ足す(足さないと落ちる)。RefGuard.keyboardWarning は渡された値を転送するだけなので対象外
    private static let resolveSites: [String: String] = [
        "FTCore/CoordinateGuards.swift": "座標ガード",
        "FTCore/PinchRegion.swift": "ピンチの領域",
        "FTCore/ScrollFrameCandidates.swift": "スクロール容器の候補",
        "FTCore/SelectorNaming.swift": "セレクタ命名の被覆",
        "FTCore/StepExecutor+ActionHelpers.swift": "visibleDragArea(キーボードを除いたドラッグの範囲)",
        "FTCore/StepExecutor+Actions.swift": "DSL の tap / doubleTap・ドラッグ",
        "FTCore/StepExecutor+Assert.swift": "assert の可視性",
        "FTCore/StepExecutor+DirectActions.swift": "直接操作(入力・Enter)",
        "FTCore/StepExecutor+Hold.swift": "hold",
        "FTCore/StepExecutor+KeyboardCover.swift": "liftCoveredTarget(覆いの下から送り出す)",
        "FTCore/StepExecutor+PreTouch.swift": "撃つ前の確かめ",
        "FTCore/StepExecutor+ScrollFrame.swift": "スクロール枠",
        "FTCore/StepExecutor+ScrollSearch.swift": "スクロール探索",
        "FTCore/StepExecutor+TypeClear.swift": "打つ・消す",
        "FTCore/StepExecutor+VisibilityPipeline.swift": "可視性検証(guardKeyboardFrame)",
        "FTCore/TreeCoverage.swift": "木の被覆",
        "fleetest-mcp/MCPServer+GesturesTools.swift": "ft_double_tap",
        "fleetest-mcp/MCPServer+Hints.swift": "MCP のヒント",
        "fleetest-mcp/MCPServer+ScrollTools.swift": "ft_scroll の着地",
        "fleetest-mcp/MCPServer+Snapshot.swift": "ft_tap",
    ]

    /// `.keyboardFrame` を resolve のないファイルで読む箇所(生の申告 = chrome 除外を持ち回らない)
    private static let rawReaders: [String: String] = [
        "FTCore/BridgeDTO.swift": "欄の宣言",
        "FTCore/KeyboardWait.swift": "出ているかの判定そのもの(画面内の矩形かどうか)",
        "FTCore/StepExecutor+SystemUIWait.swift": "打つ前の枠を控えるだけ(retypeRescueKeyboardFrame。比べる側が使う)",
        "FTCore/AppIconLocator.swift": "KeyboardWait.isShown で出ているときだけ枠を返す(SpringBoard の木のアイコン探し)",
        "FTCore/StepExecutor+ClearResidual.swift": "欄との重なりだけを見る(隠れたキーボードの画面外の矩形は重ならない)",
        "FTCore/StepExecutor+RenderCollapse.swift": "アプリの領域から除くだけ(画面外の矩形は何も除かない)",
        "FTCore/StepExecutor+XCUITestTreeConsult.swift": "KeyboardWait.isShown と組で渡す(出ていないときは枠を見ない)",
        "fleetest-mcp/MCPServer+Batch.swift": "carryPendingTypeKeyboardCheck へ控えを渡すだけ",
    ]

    func testAllResolveSitesBuildKeyboardOcclusionFromTheSnapshot() throws {
        let sources = try allSources()
        var found: Set<String> = []
        var raw: Set<String> = []
        for (path, text) in sources {
            let compacted = compact(text)
            let calls = compacted.components(separatedBy: "KeyboardOcclusion.resolve(reported:").count - 1
            if calls > 0 {
                found.insert(path)
                // 申告(keyboardFrame)から作っていること
                let fed = matches(#"KeyboardOcclusion\.resolve\(reported:[^,)]*[kK]eyboardFrame"#, in: compacted)
                XCTAssertEqual(fed, calls, "\(path) の KeyboardOcclusion.resolve に keyboardFrame 以外が渡っている")
            }
            if matches(#"\.keyboardFrame\b(?!\()"#, in: text) > 0 { raw.insert(path) }
        }
        XCTAssertEqual(found, Set(Self.resolveSites.keys),
                       "KeyboardOcclusion.resolve を呼ぶファイルが表と違う。新しい呼び出し元は resolveSites へ(理由1行)足す。"
                       + "表の行が消えた/移したなら移した先へ直す(生の keyboardFrame へ後退していないか)")
        XCTAssertEqual(raw.subtracting(found), Set(Self.rawReaders.keys),
                       "keyboardFrame を resolve を通さず読むファイルが表と違う。resolve を通すか rawReaders へ理由付きで足す")
        XCTAssertGreaterThanOrEqual(sources.count, 100, "Sources の走査が空に近い")
    }

    /// RefGuard 側は`KeyboardOcclusion` を受け取って転送するだけ。生の `FTRect?` を
    /// keyboardFrame という名で受ける古いシグネチャへ戻っていないこと
    func testRefGuardKeyboardWarningTakesKeyboardOcclusionNotARawFrame() throws {
        let text = compact(try source("fleetest-mcp/RefGuard.swift"))
        XCTAssertTrue(text.contains(compact("keyboardWarning(_ element: ElementInfo, keyboardOcclusion: KeyboardOcclusion)")),
                      "RefGuard.keyboardWarning が KeyboardOcclusion を受けていない")
        XCTAssertTrue(text.contains(compact("preTapWarnings(_ element: ElementInfo, keyboardOcclusion: KeyboardOcclusion, suppressKeyboardWarning: Bool, clearsTopBand: Bool, overlayWindows: OverlayWindowOcclusion, safeAreaTop: SafeAreaTop, screen: FTRect)")),
                      "RefGuard.preTapWarnings が KeyboardOcclusion / OverlayWindowOcclusion を受けていない")
    }

    /// `TapTargetGeometry.advisory` の keyboard 引数も KeyboardOcclusion であること
    /// (doubleTap の gestureAdvisory がここを通る唯一の経路)。
    /// **既定値は置かない** —— 申告由来の遮蔽は呼び忘れをコンパイルで止める(2026-08-28)
    func testTapTargetGeometryAdvisoryTakesKeyboardOcclusionWithoutADefault() throws {
        let text = compact(try source("FTCore/TapTargetGeometry.swift"))
        XCTAssertTrue(text.contains(compact("keyboardOcclusion: KeyboardOcclusion,")),
                      "TapTargetGeometry.advisory が KeyboardOcclusion を取っていない")
        XCTAssertFalse(text.contains(compact("keyboardOcclusion: KeyboardOcclusion = .none")),
                       "既定引数が復活している(呼び忘れがコンパイルで止まらなくなる)")
    }

    /// **画面の外のキーボードを「覆っている」と言わない**(MCP の注記まで通す)。
    /// 実測(Apple マップ・画面高 874pt): `the soft keyboard covers (0,891 402x233)` と出ていた
    func testKeyboardCoverageNoteIsSilentForAKeyboardBelowTheScreen() {
        let row = ElementInfo(ref: 1, type: "button", identifier: "row", label: "行", value: nil,
                              placeholder: nil, enabled: true,
                              frame: FTRect(x: 16, y: 820, width: 370, height: 40), depth: 2)
        func snapshot(_ keyboard: FTRect) -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: "com.apple.Maps",
                             screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                             elements: [row], truncatedCount: 0, keyboardFrame: keyboard)
        }
        XCTAssertEqual(MCPServer.keyboardCoverageNote(snapshot(FTRect(x: 0, y: 891, width: 402, height: 233))), "")
        XCTAssertTrue(MCPServer.keyboardCoverageNote(snapshot(FTRect(x: 0, y: 600, width: 402, height: 274)))
            .contains("the soft keyboard covers"), "画面に掛かっているキーボードは従来どおり言う")
    }
}
