import XCTest
@testable import FTCore

/// /clear の削除チャンク分割(ランナーが使う純粋関数)。1チャンク ≦ 数秒・合計は元の本数
final class ClearChunkingTests: XCTestCase {

    func testChunkSizeIsPinned() {
        XCTAssertEqual(ClearChunking.charactersPerChunk, 100)
        // 約 28ms/字 × チャンク = 数秒以内
        XCTAssertLessThanOrEqual(Double(ClearChunking.charactersPerChunk) * 0.028, 3)
    }

    func testChunksSplitAndSumToTheCount() {
        XCTAssertEqual(ClearChunking.chunks(for: 0), [])
        XCTAssertEqual(ClearChunking.chunks(for: -3), [])
        XCTAssertEqual(ClearChunking.chunks(for: 1), [1])
        XCTAssertEqual(ClearChunking.chunks(for: 100), [100])
        XCTAssertEqual(ClearChunking.chunks(for: 101), [100, 1])
        XCTAssertEqual(ClearChunking.chunks(for: 250), [100, 100, 50])
        for n in [7, 99, 100, 101, 999, 3000] {
            XCTAssertEqual(ClearChunking.chunks(for: n).reduce(0, +), n)
        }
    }

    func testBudgetKeepsTheFloorAndGrowsForLongText() {
        XCTAssertEqual(ClearChunking.runnerSecondsPerCharacter, 0.04)
        XCTAssertEqual(ClearChunking.budgetSeconds(floor: 8, characters: 0), 8)
        XCTAssertEqual(ClearChunking.budgetSeconds(floor: 8, characters: 100), 8)
        XCTAssertEqual(ClearChunking.budgetSeconds(floor: 8, characters: 1000), 40, accuracy: 0.001)
        XCTAssertEqual(ClearChunking.budgetSeconds(floor: 8, characters: -5), 8)
    }
}
