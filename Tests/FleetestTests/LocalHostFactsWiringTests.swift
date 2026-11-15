// 手元の run のたびに「この機械のホスト名 → local」の組を facts へ書く(RemoteHostFactsStore.saveLocal)。
// 外すと手元1台だけの利用者の画面(ダッシュボード・テストセッション)にホスト名が出て、「マシンの健全性」が
// local とホスト名の2行に割れる —— 緑のまま戻るのでソースで固定する。run と api run が共有する
// ProfileRunner.prepareEnvironment の中に置く(呼び手が2つともここを通ることは RunHookDryRunWiringTests が見る)。

import XCTest

final class LocalHostFactsWiringTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testPrepareEnvironmentWritesTheLocalHostFacts() throws {
        let text = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Sources/fleetest/ProfileRunner+Supply.swift"), encoding: .utf8)
        guard let start = text.range(of: "static func prepareEnvironment(") else {
            return XCTFail("ProfileRunner.prepareEnvironment not found")
        }
        let rest = text[start.upperBound...]
        // 関数の本体 = 次の `static func` まで
        let body = rest.range(of: "static func ").map { rest[..<$0.lowerBound] } ?? rest
        XCTAssertTrue(body.contains("RemoteHostFactsStore.saveLocal("),
                      "prepareEnvironment must record this Mac's hostname → local pair (RemoteHostFactsStore.saveLocal)")
    }
}
