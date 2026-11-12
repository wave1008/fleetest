// Android の NumberPicker を合わせるホスト側のループ(`PickerValueLoop`)。ブリッジは偽(値の並びを循環/端つきで持つ)。
// 止める条件は観測できる事象だけ: 一致 / 送れなかった / 値が動かない(端) / 既出の値に戻った(一周)。

import XCTest
@testable import FTCore

final class PickerValueLoopTests: XCTestCase {

    /// values を循環(wraps)または端つきで送る偽のホイール。送った向きを記録する
    private final class FakeWheel: @unchecked Sendable {
        let values: [String]
        let wraps: Bool
        var index: Int
        private(set) var sent: [PickerValueMatch.Step] = []
        var performed = true
        var unreadable = false
        init(_ values: [String], at start: Int, wraps: Bool = true) {
            self.values = values; self.index = start; self.wraps = wraps
        }
        var current: String { values[index] }
        func step(_ direction: PickerValueMatch.Step) -> PickerStepResult {
            sent.append(direction)
            guard performed else { return PickerStepResult(performed: false, value: current) }
            let next = index + (direction == .forward ? 1 : -1)
            if wraps { index = (next + values.count) % values.count }
            else if next >= 0 && next < values.count { index = next }
            return PickerStepResult(performed: true, value: unreadable ? nil : current)
        }
    }

    private func run(_ wheel: FakeWheel, wanted: String, start: String? = nil) async throws -> PickerValueOutcome {
        try await PickerValueLoop.run(start: start ?? wheel.current, wanted: wanted) { wheel.step($0) }
    }

    private let hours = (0..<24).map { String(format: "%02d", $0) }

    func testAlreadyMatchingSendsNothing() async throws {
        let wheel = FakeWheel(hours, at: 14)
        let outcome = try await run(wheel, wanted: "14")
        XCTAssertEqual(outcome, PickerValueOutcome(value: "14", steps: 0))
        XCTAssertEqual(wheel.sent, [])
    }

    func testStopsOnMatchGoingForwardAndBackward() async throws {
        let forward = FakeWheel(hours, at: 14)
        let forwardOutcome = try await run(forward, wanted: "17")
        XCTAssertEqual(forwardOutcome.steps, 3)
        XCTAssertEqual(forward.sent, [.forward, .forward, .forward])
        let backward = FakeWheel(hours, at: 14)
        let backwardOutcome = try await run(backward, wanted: "12")
        XCTAssertEqual(backwardOutcome.value, "12")
        XCTAssertEqual(backward.sent, [.backward, .backward])
    }

    func testNonNumericGuessesForwardAndFlipsOnceAtTheEnd() async throws {
        let months = ["Jan", "Feb", "Mar", "Apr"]
        let wheel = FakeWheel(months, at: 2, wraps: false)
        let outcome = try await run(wheel, wanted: "Jan")
        XCTAssertEqual(outcome.value, "Jan")
        XCTAssertEqual(wheel.sent, [.forward, .forward, .backward, .backward, .backward],
                       "端で動かなかったら1度だけ反対へ振る(Apr の次は動かない → 反対へ)")
    }

    func testStopsWhenTheValueDoesNotChangeAtTheEnd() async throws {
        let wheel = FakeWheel(hours, at: 22, wraps: false)
        do {
            _ = try await run(wheel, wanted: "30")   // 範囲外: 数値の向きは forward・端で止まる
            XCTFail("端で止まるはず")
        } catch let failure as PickerValueLoop.Failure {
            guard case let .stopped(last, wanted, reason) = failure else { return XCTFail() }
            XCTAssertEqual(last, "23")
            XCTAssertEqual(wanted, "30")
            XCTAssertTrue(reason.contains("did not change"), reason)
            XCTAssertEqual(wheel.sent.count, 2, "動かなかった回で止まる(数値の向きは反対へ振らない)")
        }
    }

    func testStopsAfterOneFullTurnOfAWrappingWheel() async throws {
        let wheel = FakeWheel(hours, at: 3)
        do {
            _ = try await run(wheel, wanted: "99")
            XCTFail("一周で止まるはず")
        } catch let failure as PickerValueLoop.Failure {
            guard case let .stopped(last, _, reason) = failure else { return XCTFail() }
            XCTAssertEqual(last, "03")
            XCTAssertTrue(reason.contains("all the way round"), reason)
            XCTAssertEqual(wheel.sent.count, 24, "一周 = 値の数だけ送って開始値に戻る")
        }
    }

    func testStopsWhenTheBridgeCouldNotScrollOrReadTheValue() async throws {
        let refused = FakeWheel(hours, at: 3)
        refused.performed = false
        do {
            _ = try await run(refused, wanted: "10")
            XCTFail()
        } catch let failure as PickerValueLoop.Failure {
            XCTAssertTrue(failure.description.contains("could not scroll"), failure.description)
            XCTAssertEqual(refused.sent.count, 1, "送れなかったら重ねて撃たない")
        }
        let blind = FakeWheel(hours, at: 3)
        blind.unreadable = true
        do {
            _ = try await run(blind, wanted: "10")
            XCTFail()
        } catch let failure as PickerValueLoop.Failure {
            XCTAssertTrue(failure.description.contains("could not be read"), failure.description)
            XCTAssertEqual(blind.sent.count, 1, "読めなければ次を撃たない(届いたか分からない送りを重ねない)")
        }
    }

    func testUnknownStartStillFindsTheValue() async throws {
        let wheel = FakeWheel(hours, at: 5)
        let outcome = try await PickerValueLoop.run(start: nil, wanted: "07") { wheel.step($0) }
        XCTAssertEqual(outcome.value, "07")
    }
}
