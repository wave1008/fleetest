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
            XCTAssertEqual(wheel.sent.count, 4 + 5 + 1,
                           "逆向きを4段試して戻り(一周しない)、端で動かなかった回で止まる(数値の向きは反対へ振らない)")
        }
    }

    func testStopsAfterOneFullTurnOfAWrappingWheel() async throws {
        let wheel = FakeWheel(hours, at: 3)
        do {
            _ = try await run(wheel, wanted: "99")
            XCTFail("一周で止まるはず")
        } catch let failure as PickerValueLoop.Failure {
            guard case let .stopped(last, _, reason) = failure else { return XCTFail() }
            XCTAssertEqual(last, "23", "逆向きで一周(03 → 23)を見た後、そこから一周して戻る")
            XCTAssertTrue(reason.contains("all the way round"), reason)
            XCTAssertEqual(wheel.sent.count, 4 + 24, "逆向きの4段 + 一周 = 値の数だけ送って戻る")
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
            XCTAssertEqual(refused.sent.count, 2,
                           "送れなかった(撃つ前に断られた = 届いていない)ら、逆向きを試すのをやめ、数値の向きで1回だけ試して止まる")
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

    /// **一周する分のホイールは逆向きで近道する**(実測: Google マップの分を 53 → 00 で後ろへ約50段・17.3 秒)
    func testAWrappingWheelTakesTheShortWayRound() async throws {
        let minutes = (0..<60).map { String(format: "%02d", $0) }
        let wheel = FakeWheel(minutes, at: 53)
        let outcome = try await run(wheel, wanted: "00")
        XCTAssertEqual(outcome.value, "00")
        XCTAssertEqual(wheel.sent, Array(repeating: .forward, count: 7), "前へ7段(53 → 59 → 00)")
    }

    /// 一周しないホイールでは試した分だけ戻る(上乗せは試した段数の往復 = 数値の向きの段数以下)
    func testANonWrappingWheelComesBackAfterTheProbe() async throws {
        let years = (2000...2060).map(String.init)
        let wheel = FakeWheel(years, at: 50, wraps: false)   // 2050 → 2010(後ろへ40段)
        let outcome = try await run(wheel, wanted: "2010")
        XCTAssertEqual(outcome.value, "2010")
        XCTAssertEqual(wheel.sent.filter { $0 == .forward }.count, 11, "前へ試すのは端(2060)までの10段 + 端で動かなかった1回")
        XCTAssertLessThanOrEqual(wheel.sent.count, 40 * 2)
    }

    func testUnknownStartStillFindsTheValue() async throws {
        let wheel = FakeWheel(hours, at: 5)
        let outcome = try await PickerValueLoop.run(start: nil, wanted: "07") { wheel.step($0) }
        XCTAssertEqual(outcome.value, "07")
    }
}
