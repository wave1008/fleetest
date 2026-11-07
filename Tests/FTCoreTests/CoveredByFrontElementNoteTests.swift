import XCTest
@testable import FTCore

/// 塗り順が本物の木で、tap なら撃つ前に断る覆いの下にある要素への exist は、合否を変えずに `covered-by-front-element` を付ける
/// (35周目 im4 F2: RN の払う前の行の裏のスワイプのボタンへの exist が 13/13 で ✅、同じ要素への tap は「露出 0」で断っていた)
final class CoveredByFrontElementNoteTests: XCTestCase {
    private func element(_ ref: Int, _ type: String, _ id: String, _ label: String, _ frame: FTRect, z: Int?, depth: Int) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil, placeholder: nil, enabled: true,
                    frame: frame, depth: depth, z: z)
    }

    private func exist(_ elements: [ElementInfo]) async -> StepOutcome {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [elements])
        let executor = StepExecutor(driver: driver, occlusionOCRMode: .off, isAndroid: false, tunables: RunTunables())
        return await executor.execute(FlowStep(assert: "exists", locator: FlowLocator(id: "btn_archive"),
                                               timeout: 0, occlusionGuard: true))
    }

    func testExistUnderAPressableRowIsNotedButStillPasses() async {
        // 行(手前・z 2)がボタン(裏・z 1)を丸ごと覆う = 払う前のスワイプのボタン
        let row = element(1, "clickable", "sw_row_3", "行 3", FTRect(x: 0, y: 300, width: 400, height: 60), z: 2, depth: 1)
        let button = element(2, "button", "btn_archive", "アーカイブ", FTRect(x: 300, y: 300, width: 100, height: 60), z: 1, depth: 1)
        let outcome = await exist([row, button])
        guard case .passed = outcome.status else { return XCTFail("合否を変えた: \(outcome.status)") }
        XCTAssertTrue(outcome.notes.contains(.coveredByFrontElement), "\(outcome.notes)")
    }

    func testNoNoteWhenNothingCoversOrPaintOrderIsUnknown() async {
        let row = element(1, "clickable", "sw_row_3", "行 3", FTRect(x: 0, y: 300, width: 280, height: 60), z: 2, depth: 1)
        let button = element(2, "button", "btn_archive", "アーカイブ", FTRect(x: 300, y: 300, width: 100, height: 60), z: 1, depth: 1)
        let apart = await exist([row, button])
        XCTAssertFalse(apart.notes.contains(.coveredByFrontElement), "覆われていないのに付いた")
        // 塗り順の無い木(z が無い = SwiftUI・CMP・Flutter)では推測しない
        // 行を木の後ろ(ref 3)に置く = 木の順で読めば行が手前。塗り順を見ない実装ならここで注記が出る
        var coveringRow = row; coveringRow.frame = FTRect(x: 0, y: 300, width: 400, height: 60); coveringRow.z = nil; coveringRow.ref = 3
        var bare = button; bare.z = nil
        let unknown = await exist([coveringRow, bare])
        XCTAssertFalse(unknown.notes.contains(.coveredByFrontElement), "塗り順の無い木で手前を推測した")
    }
}
