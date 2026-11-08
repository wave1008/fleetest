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
        XCTAssertTrue(outcome.driverFallback?.contains("an element drawn in front of it covers it") == true,
                      "文言がステップの説明に出ない: \(outcome.driverFallback ?? "nil")")
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

    /// 在り続けた覆われた要素への notExist の赤は覆いを名指す(36周目 im4 F2: 「element still exists」だけだった)。塗り順の無い木では言わない
    func testNotExistFailureNamesTheFrontElementOnlyWithPaintOrder() async {
        let row = element(1, "clickable", "sw_row_3", "行 3", FTRect(x: 0, y: 300, width: 400, height: 60), z: 2, depth: 1)
        let button = element(2, "button", "btn_archive", "アーカイブ", FTRect(x: 300, y: 300, width: 100, height: 60), z: 1, depth: 1)
        let real = await notExist([row, button])
        XCTAssertTrue(real.contains("#sw_row_3 covers it"), real)
        var coveringRow = row; coveringRow.z = nil; coveringRow.ref = 3
        var bare = button; bare.z = nil
        let unknown = await notExist([coveringRow, bare])
        XCTAssertTrue(unknown.contains("element still exists"), unknown)
        XCTAssertFalse(unknown.contains("covers it"), "塗り順の無い木で手前を推測した: \(unknown)")
    }

    private func notExist(_ elements: [ElementInfo]) async -> String {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [elements])
        let executor = StepExecutor(driver: driver, occlusionOCRMode: .off, isAndroid: false, tunables: RunTunables())
        let outcome = await executor.execute(FlowStep(assert: "notExists", locator: FlowLocator(id: "btn_archive"), timeout: 0))
        guard case .failed(let message) = outcome.status else { return "not failed: \(outcome.status)" }
        return message
    }

    /// Android のアプリ自身のダイアログの窓が手前のとき、見つからない exist の赤はダイアログを名指す(36周目 amax F2。tap の赤と同じ)
    func testExistFailureNamesTheAppsOwnDialogWindow() async {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[
            element(1, "button", "btn_open", "開く", FTRect(x: 0, y: 100, width: 200, height: 60), z: nil, depth: 1)]])
        let executor = StepExecutor(driver: driver, occlusionOCRMode: .off, isAndroid: true, tunables: RunTunables())
        executor.foregroundWindowLines = { _ in ["com.example.app/Dialog " + StepExecutor.ownDialogWindowMarker] }
        let outcome = await executor.execute(FlowStep(assert: "exists", locator: FlowLocator(id: "row_behind"), timeout: 0))
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(message.contains("the app's own dialog window is in front"), message)
    }
}
