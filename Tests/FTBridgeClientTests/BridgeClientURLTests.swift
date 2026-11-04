// ブリッジへ投げる URL の組み立て。**クエリ付きの経路がここで壊れた実績がある**。
//
// 2026-08-02: `snapshot(bypassingCache:)` が "/snapshot?refresh=1" を path として渡していたため
// `appendingPathComponent` が "?" を %3F へ逃がし、ブリッジ側で
// `GET /snapshot%3Frefresh=1` = 404 になった。フェイクドライバの単体テストは
// 「どちらのドライバへ流れたか」しか見ないので配線が通らず、**期限切れ時にしか撃たない経路**
// だったため E2E でも長く表面化しなかった(実データで初めて出た)。
// URL 組み立てだけを純粋関数として切り出し、ここで固定する。

import XCTest
@testable import FTBridgeClient
import FTCore

final class BridgeClientURLTests: XCTestCase {

    private let base = URL(string: "http://127.0.0.1:8123")!

    func testPlainPathHasNoQuery() {
        let url = BridgeClient.url(base: base, path: "/snapshot", query: nil)
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:8123/snapshot")
    }

    /// "?" がパス要素としてエスケープされないこと(これが 404 の正体だった)
    func testQueryIsAppendedAsQueryNotEscapedIntoThePath() {
        let url = BridgeClient.url(base: base, path: "/snapshot", query: "refresh=1")
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:8123/snapshot?refresh=1")
        XCTAssertFalse(url.absoluteString.contains("%3F"), "'?' がパスへ逃げている")
        XCTAssertEqual(url.path, "/snapshot", "ルーティングに使う path はクエリを含まないこと")
        XCTAssertEqual(url.query, "refresh=1")
    }

    func testEmptyQueryIsTreatedAsNone() {
        let url = BridgeClient.url(base: base, path: "/snapshot", query: "")
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:8123/snapshot")
    }

    /// `GET /hittable` の素性の照会: ランナー(`BridgeHTTPServer.Request.queryValue` = `&` と最初の `=` で割るだけ →
    /// `handleHittable` が `removingPercentEncoding` を1回)と同じ手順で戻すと元の値になること。
    /// `query` の setter へ符号化済みの値を渡すと `%` が二重に符号化され、日本語のラベルで必ず引き当てに失敗していた
    func testHitTestQueryRoundTripsThroughTheRunnersSingleDecode() {
        let label = "行 A&b=c+d%e#f?"
        let query = HitTestQuery(identifier: "row_main_07", label: label, type: "button",
                                 frame: FTRect(x: 0, y: 528.5, width: 402, height: 56))
        let url = BridgeClient.url(base: base, path: "/hittable", query: BridgeClient.hitTestQueryString(query),
                                   percentEncoded: true)
        let raw = try! XCTUnwrap(url.query(percentEncoded: true))
        func value(_ key: String) -> String? {
            for pair in raw.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2, kv[0] == Substring(key) { return String(kv[1]).removingPercentEncoding }
            }
            return nil
        }
        XCTAssertEqual(value("label"), label)
        XCTAssertEqual(value("identifier"), "row_main_07")
        XCTAssertEqual(value("y"), "528.5")
        XCTAssertEqual(value("h"), "56.0")
    }
}
