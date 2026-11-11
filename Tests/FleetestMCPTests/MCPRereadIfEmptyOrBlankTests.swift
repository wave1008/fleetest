// snapshotAfter と ft_batch の最終読みが共有する「空/何も読めない木の1回撮り直し」。
// 定義は MCPServer.rereadIfEmptyOrBlank の1つだけ(ft_batch が撮り直さず空の木を返した件)。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPRereadIfEmptyOrBlankTests: XCTestCase {
    private func snap(_ elements: [ElementInfo], marker: Int) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "marker-\(marker)",
                         screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                         elements: elements, truncatedCount: 0)
    }

    private func label(_ ref: Int) -> ElementInfo {
        ElementInfo(ref: ref, type: "staticText", identifier: "t", label: "Hello", value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 1)
    }

    /// 何も読めない木 → 1回だけ撮り直し、撮り直した木を返す。外せば nil で撮り直さず落ちる
    func testBlankTreeIsReReadOnceAndTheReReadIsReturned() async throws {
        var calls = 0
        let r = await MCPServer.rereadIfEmptyOrBlank(snap([], marker: 0)) {
            calls += 1
            return self.snap([self.label(1)], marker: 99)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(r?.snapshot.sessionBundleID, "marker-99")
        XCTAssertTrue(r?.note.contains("nothing readable") == true)
        XCTAssertTrue(r?.note.contains("re-read once") == true)
    }

    /// 撮り直しても読めない → 「まだ読めない」と言う(黙らない)
    func testStillBlankAfterReReadSaysSo() async throws {
        let r = await MCPServer.rereadIfEmptyOrBlank(snap([], marker: 0)) { self.snap([], marker: 1) }
        XCTAssertTrue(r?.note.contains("still had nothing readable") == true)
    }

    /// 読める木は撮り直さない(無駄待ちを払わない)
    func testReadableTreeIsNotReRead() async throws {
        var calls = 0
        let r = await MCPServer.rereadIfEmptyOrBlank(snap([label(1)], marker: 0)) {
            calls += 1
            return self.snap([], marker: 9)
        }
        XCTAssertNil(r)
        XCTAssertEqual(calls, 0)
    }

    /// ft_batch: 無変化の撮り直しが無く、最後の木が何も読めない → 1回撮り直して返す。外すと空の木が返る
    func testBatchFinalReadReReadsABlankTree() async throws {
        var calls = 0
        let r = await MCPServer.batchFinalSettle(unchangedNote: "", final: snap([], marker: 0)) {
            calls += 1
            return self.snap([self.label(1)], marker: 7)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(r.snapshot.sessionBundleID, "marker-7")
        XCTAssertTrue(r.note.contains("nothing readable"), r.note)
    }

    /// ft_batch: 無変化の撮り直しを既に払った回は重ねない(待ちを二重に払わない)
    func testBatchFinalReadDoesNotStackOnTheUnchangedReRead() async throws {
        var calls = 0
        let r = await MCPServer.batchFinalSettle(unchangedNote: "note: unchanged\n", final: snap([], marker: 0)) {
            calls += 1
            return self.snap([self.label(1)], marker: 7)
        }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(r.note, "note: unchanged\n")
    }

    /// 両方の経路(snapshotAfter・ft_batch)が同じ関数を呼んでいる(片方だけ外すと落ちる)
    func testBothPathsUseTheSharedHelper() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest-mcp")
        for f in ["MCPServer+Snapshot.swift", "MCPServer+Batch.swift"] {
            // Batch は batchFinalSettle 経由(同じファイルの中で rereadIfEmptyOrBlank を呼ぶ)
            let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
            XCTAssertTrue(text.contains("rereadIfEmptyOrBlank("), "\(f) must call the shared re-read helper")
        }
    }
}
