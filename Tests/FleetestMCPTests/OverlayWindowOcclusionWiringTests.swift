// **MCP と DSL の全呼び出し元が OverlayWindowOcclusion を通ること**の配線ゲート
// (`KeyboardOcclusionWiringTests` と同型)。判定そのものは OverlayWindowOcclusionTests が
// 見るが、「呼び出し側が申告を渡さず `.none` を作って握り潰す」変異はコンパイラでは止まらない
// ので、各ファイルのソースを読んで **そのスナップショットの overlayWindowFrames から**
// 作られていることまで見る。

import XCTest

final class OverlayWindowOcclusionWiringTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/FleetestMCPTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // リポジトリ直下

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent("Sources/" + relativePath),
                    encoding: .utf8)
    }

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

    private func count(_ pattern: String, in text: String) -> Int {
        text.components(separatedBy: pattern).count - 1
    }

    /// `OverlayWindowOcclusion.resolve(reported:` を呼ぶファイル。**ft_tap・ft_double_tap・ft_* の注記・DSL の tap/doubleTap/hold/打つ・
    /// linkText が同じ被覆でなければならない** —— 新しい呼び出し元はここへ足す(足さないと落ちる)。足すときは、
    /// 引数がそのスナップショットの overlayWindowFrames であること(下の検査)
    private static let resolveSites: [String: String] = [
        "FTCore/StepExecutor+Actions.swift": "DSL の tap / doubleTap",
        "FTCore/StepExecutor+Hold.swift": "DSL の hold",
        "FTCore/StepExecutor+LinkText.swift": "linkText の座標の遮蔽",
        "FTCore/StepExecutor+PreTouch.swift": "打つ・消すの前の注記",
        "fleetest-mcp/MCPServer+GesturesTools.swift": "ft_double_tap",
        "fleetest-mcp/MCPServer+Hints.swift": "MCP の遮蔽ヒント",
        "fleetest-mcp/MCPServer+Snapshot.swift": "ft_tap",
    ]

    /// `.overlayWindowFrames` を resolve 以外で読むファイル(生の申告を持ち回る = resolve が捨てる使えない枠も混ざる)
    private static let rawReaders: [String: String] = [
        "FTCore/BridgeDTO.swift": "欄の宣言",
        "FTCore/StepExecutor+DirectActions.swift": "キーボードを閉じる点の候補から避ける矩形として使うだけ(resolve が捨てる面積 0 の矩形は点を含まないので結果は同じ)",
    ]

    func testAllResolveSitesBuildFromTheSnapshotsDeclaredFrames() throws {
        let sources = try allSources()
        var found: Set<String> = []
        var raw: Set<String> = []
        for (path, text) in sources {
            let compacted = compact(text)
            let calls = count("OverlayWindowOcclusion.resolve(reported:", in: compacted)
            if calls > 0 {
                found.insert(path)
                // 申告から作っていること(常に .none を渡す抜け殻になっていないか)
                let fed = matches(#"OverlayWindowOcclusion\.resolve\(reported:[^,)]*overlayWindowFrames"#, in: compacted)
                XCTAssertEqual(fed, calls, "\(path) の OverlayWindowOcclusion.resolve に overlayWindowFrames 以外が渡っている")
            }
            if text.contains(".overlayWindowFrames") { raw.insert(path) }
        }
        XCTAssertEqual(found, Set(Self.resolveSites.keys),
                       "OverlayWindowOcclusion.resolve を呼ぶファイルが表と違う。新しい呼び出し元は resolveSites へ(理由1行)足す。"
                       + "表の行が消えた/移したなら、移した先へ表を直す(消えた呼び出しは配線の退化)")
        XCTAssertEqual(raw.subtracting(found), Set(Self.rawReaders.keys),
                       "overlayWindowFrames を resolve を通さず読むファイルが表と違う。resolve を通すか rawReaders へ理由付きで足す")
        XCTAssertGreaterThanOrEqual(sources.count, 100, "Sources の走査が空に近い")
    }

    /// RefGuard 側は受け取って転送するだけ。**既定引数を置かない**(呼び忘れを
    /// コンパイルで止める規律。置くと新しい呼び出し元が黙って警告を失う)
    func testRefGuardTakesTheOcclusionWithoutADefault() throws {
        let text = compact(try source("fleetest-mcp/RefGuard.swift"))
        XCTAssertTrue(text.contains(compact("overlayWindowWarning(_ element: ElementInfo, overlayWindows: OverlayWindowOcclusion)")),
                      "RefGuard.overlayWindowWarning のシグネチャが違う")
        XCTAssertTrue(text.contains(compact("overlayWindows: OverlayWindowOcclusion,")),
                      "RefGuard.preTapWarnings が OverlayWindowOcclusion を受けていない")
        XCTAssertFalse(text.contains(compact("overlayWindows: OverlayWindowOcclusion = .none")),
                       "既定引数が置かれている(呼び忘れがコンパイルで止まらなくなる)")
    }

    /// **BridgeClient が写像を FTCore へ委ねていること**。`hittable` 欠落を素で
    /// `.unavailable` へ畳む実装に戻すと、木が画面を代表していないことを知る唯一の答えが
    /// 捨てられる —— その退化は FakeDriver 経由の MCP テストでは落ちない(2026-08-28 の
    /// 変異チェックで実際に生き残った)ので、配線をここで縛る
    func testBridgeClientMapsTheHitTestAnswerThroughFTCore() throws {
        let text = compact(try source("FTBridgeClient/BridgeClient.swift"))
        XCTAssertTrue(text.contains("HitTestAnswer.fromBridge(hittable:answer.hittable)"),
                      "BridgeClient が HitTestAnswer.fromBridge を通していない")
    }

    /// **ブリッジ側の申告が消えていないこと**。ホストだけ直しても、Android の
    /// SnapshotBuilder が overlayWindowFrames を出さなければ判定材料は永久に来ない
    /// (この配線は Java と Swift をまたぐのでコンパイラは何も言わない)
    func testAndroidBridgeStillDeclaresOverlayWindowFrames() throws {
        let bridge = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "AndroidRunner/src/com/example/ftbridge/SnapshotBuilder.java"),
            encoding: .utf8)
        XCTAssertTrue(bridge.contains("\"overlayWindowFrames\""),
                      "SnapshotBuilder が overlayWindowFrames を申告していない")
        XCTAssertTrue(bridge.contains("TYPE_APPLICATION"),
                      "オーバーレイの種別判定(TYPE_APPLICATION)が消えている")
        // **アクティブより手前だけ**を数える条件。落とすと奥のウィンドウまで拾う
        XCTAssertTrue(compact(bridge).contains(compact("window.getLayer() <= activeLayer")),
                      "手前かどうかを layer で見る条件が消えている")
        // **IME は keyboardFrame の担当**。ここへ混ぜると同じ事実を2回言う
        XCTAssertTrue(bridge.contains("TYPE_INPUT_METHOD"),
                      "IME を overlayWindowFrames から外す分岐が消えている")
    }
}
