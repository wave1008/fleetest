// **別の AppDriver を包んで持つドライバは `hitTest(query:)` を必ず転送する**ことを守る。
//
// 既定実装は「答えられない」(`.unavailable`)で、呼び手(撃つ前の照会)はそれを「何も変えない」に畳む。
// 包む型が転送を忘れると照会は**最初のラッパーで黙って消え**、断るはずの形が ok のまま通る —— 失敗モードが
// 沈黙なので、偽ドライバの単体テストも E2E も緑のまま気付けない(inapp-boost のシナリオ実行が最外に組む
// `WebViewDelegatingDriver` が転送しておらず、デバイスで照会が一度も届かなかった)。
//
// 型を書き並べず**ソースを走査して「AppDriver 型の格納プロパティを持つのに転送が無い」型を検出する**
// (SnapshotCacheBypassForwardingTests と同じ作法。新しいラッパーも自動で対象になる)。

import XCTest

final class HitTestQueryForwardingTests: XCTestCase {

    /// 対象外。**包む相手を持たないのに走査に掛かるファイルだけ**を入れること(包む型を入れると、この防波堤が
    /// 守りたい事故そのものを見逃す)
    private static let exempt: [String: String] = [
        // 葉の `NullDriver` と、ドライバを組み立てるローカル変数 `var driver: AppDriver` が同じファイルにある(包む型ではない)
        "ScenarioRunnerMain.swift": "leaf NullDriver + local variable",
    ]

    func testEveryDriverWrappingAnotherDriverForwardsHitTestQuery() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTBridgeClientTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
        let sources = root.appendingPathComponent("Sources")
        let wrapsADriver = try NSRegularExpression(pattern: #"(let|var)\s+\w+\s*:\s*(any\s+)?AppDriver\??\s*(\n|=|$)"#,
                                                   options: [.anchorsMatchLines])
        var wrappers: [String] = []
        var missing: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        for file in files where Self.exempt[file.lastPathComponent] == nil {
            guard let source = try? String(contentsOf: file, encoding: .utf8),
                  source.range(of: #"(class|struct|actor)\s+\w+[^{\n]*:\s*[^{\n]*\bAppDriver\b"#, options: .regularExpression) != nil,
                  wrapsADriver.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil
            else { continue }
            wrappers.append(file.lastPathComponent)
            if !source.contains("func hitTest(query: HitTestQuery) async -> HitTestAnswer") {
                missing.append(file.lastPathComponent)
            }
        }
        // 走査が空振りしていないこと(包む型の代表が拾えている)
        for known in ["HybridFallbackDriver.swift", "WebViewDelegatingDriver.swift", "SessionRecoveryDriver.swift",
                      "ActionCountingDriver.swift"] {
            XCTAssertTrue(wrappers.contains(known), "走査が \(known) を包む型として拾えていない: \(wrappers.sorted())")
        }
        XCTAssertEqual(missing.sorted(), [],
                       "別のドライバを包むのに hitTest(query:) を転送していない(既定実装に落ちて照会が黙って消える): \(missing.sorted())")
    }
}
