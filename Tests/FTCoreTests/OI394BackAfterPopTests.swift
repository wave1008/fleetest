import XCTest
@testable import FTCore

/// OI-394: 直前のステップが back() だったときだけ、次の back() は before を読む前に既存の整定を待つ
/// (pop の名残の戻るボタンが木に残る間に before を読むと、after と要素数が違い「効いた」に見えて注記が欠ける)
final class OI394BackAfterPopTests: XCTestCase {

    func testSettlesOnlyWhenTheStepJustBeforeWasBack() {
        // back() の記録後のステップ数 = 3。次のステップの本体が見る記録済み数も 3
        XCTAssertTrue(BackEffect.shouldSettleBeforeRead(afterBackAtStepCount: 3, stepsRecorded: 3))
        // 間に別のステップが挟まった(記録済みが進んだ)/ back() をまだ撃っていない
        XCTAssertFalse(BackEffect.shouldSettleBeforeRead(afterBackAtStepCount: 3, stepsRecorded: 4))
        XCTAssertFalse(BackEffect.shouldSettleBeforeRead(afterBackAtStepCount: nil, stepsRecorded: 0))
    }

    private func el(_ id: String, ref: Int, y: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: "other", identifier: id, label: nil, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 0, y: y, width: 44, height: 44), depth: 0)
    }

    /// 戻るボタンが残る木 → 消えた木 → 同じ、の順に読む。固定の待ちでなく「2回続けて同じ」まで読み続ける
    func testSettleReadsUntilTwoConsecutiveTreesMatch() async {
        let withBack = [el("root", ref: 1, y: 100), el("BackButton", ref: 2, y: 16)]
        let settled = [el("root", ref: 1, y: 100)]
        let driver = FakeAppDriver(name: "p", log: CallLog(), snapshotElements: [withBack, settled, settled])
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
        await executor.settleBeforeBackObservation()
        XCTAssertEqual(driver.snapshotCallCount, 3)
    }

    /// back() の配線: 読む前の整定は before の読みの前・撃った後に次の判定用の数を控える(ソース走査 = DSL はデバイス無しで走らない)
    func testBackCommandWiring() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FTDSL/CommandsAppControl.swift"), encoding: .utf8)
        let settle = try XCTUnwrap(source.range(of: "executor.settleBeforeBackObservation()"))
        let before = try XCTUnwrap(source.range(of: "let before = await observe()"))
        let fire = try XCTUnwrap(source.range(of: "try await driver.back()"))
        let remember = try XCTUnwrap(source.range(of: "executor.backFiredAtStepCount = core.stepCounter + 1"))
        XCTAssertLessThan(settle.lowerBound, before.lowerBound)
        XCTAssertLessThan(before.lowerBound, fire.lowerBound)
        XCTAssertLessThan(fire.lowerBound, remember.lowerBound)
    }
}
