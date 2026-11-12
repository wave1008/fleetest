import XCTest
@testable import FTCore

final class SliderValueTests: XCTestCase {

    // MARK: - 照合

    /// 木に出る3つの書き方(iOS の割合・Compose の小数・Android の範囲の単位)を数で比べる
    func testNumberReadsEveryNotationTheTreesUse() {
        XCTAssertEqual(SliderValueMatch.number("75%"), 75)
        XCTAssertEqual(SliderValueMatch.number("50.0"), 50)
        XCTAssertEqual(SliderValueMatch.number("50"), 50)
        XCTAssertEqual(SliderValueMatch.number("-3.5 dB"), -3.5)
        XCTAssertEqual(SliderValueMatch.number("volume 12.25"), 12.25)
        XCTAssertNil(SliderValueMatch.number("off"))
        XCTAssertNil(SliderValueMatch.number(""))
    }

    /// **丸めない**: 刻みの無いスライダーで 33.3 に止まったのを 33 と言わない(誤った緑になる)
    func testMatchDoesNotRound() {
        XCTAssertTrue(SliderValueMatch.matches(current: "75%", wanted: 75))
        XCTAssertTrue(SliderValueMatch.matches(current: "75.0", wanted: 75))
        XCTAssertFalse(SliderValueMatch.matches(current: "33.333332", wanted: 33))
        XCTAssertFalse(SliderValueMatch.matches(current: "74%", wanted: 75))
        XCTAssertFalse(SliderValueMatch.matches(current: "n/a", wanted: 0))
    }

    // MARK: - 1段ずつ

    /// 刻み 25 のスライダー: 50 → 75 は1段で着く。向きは数の大小で決まる
    func testSteppingReachesTheValueInTheRightDirection() async throws {
        var value = 50.0
        var sent: [SliderValueLoop.Step] = []
        let outcome = try await SliderValueLoop.byStepping(start: "50%", wanted: 75) { step in
            sent.append(step)
            value += step == .increment ? 25 : -25
            return SliderStepResult(performed: true, value: "\(Int(value))%")
        }
        XCTAssertEqual(outcome, SliderValueOutcome(value: "75%", steps: 1))
        XCTAssertEqual(sent, [.increment])
    }

    func testSteppingGoesDownWhenTheValueIsAbove() async throws {
        var value = 100.0
        var sent: [SliderValueLoop.Step] = []
        _ = try await SliderValueLoop.byStepping(start: "100", wanted: 25) { step in
            sent.append(step)
            value += step == .increment ? 25 : -25
            return SliderStepResult(performed: true, value: "\(Int(value))")
        }
        XCTAssertEqual(sent, [.decrement, .decrement, .decrement])
    }

    /// 今の値で既に合っていれば撃たない
    func testAlreadyAtTheValueSendsNothing() async throws {
        let outcome = try await SliderValueLoop.byStepping(start: "75.0", wanted: 75) { _ in
            XCTFail("撃った")
            return SliderStepResult(performed: true, value: nil)
        }
        XCTAssertEqual(outcome.steps, 0)
    }

    /// **またいだら止まる**(刻み 10 で 75 は無い)。またいだ事実を言う
    func testSteppingThatSkipsTheValueStopsAndSaysSo() async throws {
        var value = 50.0
        do {
            _ = try await SliderValueLoop.byStepping(start: "50%", wanted: 75) { step in
                value += step == .increment ? 10 : -10
                return SliderStepResult(performed: true, value: "\(Int(value))%")
            }
            XCTFail("通った")
        } catch let failure as SliderValueLoop.Failure {
            XCTAssertTrue(failure.description.contains("'80%'") && failure.description.contains("past the value"),
                          failure.description)
        }
    }

    /// 端で動かなくなったら止まる(範囲の外)
    func testSteppingStopsAtTheEnd() async throws {
        do {
            _ = try await SliderValueLoop.byStepping(start: "100", wanted: 150) { _ in
                SliderStepResult(performed: true, value: "100")
            }
            XCTFail("通った")
        } catch let failure as SliderValueLoop.Failure {
            XCTAssertTrue(failure.description.contains("did not change"), failure.description)
        }
    }

    /// 読めなかったら次を撃たない(届いたか分からない送りを重ねない)
    func testUnreadableValueStopsWithoutAnotherStep() async throws {
        var calls = 0
        do {
            _ = try await SliderValueLoop.byStepping(start: "50", wanted: 75) { _ in
                calls += 1
                return SliderStepResult(performed: true, value: nil)
            }
            XCTFail("通った")
        } catch is SliderValueLoop.Failure {
            XCTAssertEqual(calls, 1)
        }
    }

    /// 今の値が読めないときは増やす向きを試し、読めた値から向きを決め直す(端なら反対へ)
    func testUnknownStartTriesIncrementThenFollowsTheReadValue() async throws {
        var value = 100.0
        var sent: [SliderValueLoop.Step] = []
        let outcome = try await SliderValueLoop.byStepping(start: nil, wanted: 75) { step in
            sent.append(step)
            if step == .decrement { value -= 25 }
            return SliderStepResult(performed: true, value: "\(Int(value))")
        }
        XCTAssertEqual(outcome.value, "75")
        XCTAssertEqual(sent, [.increment, .decrement])
    }

    // MARK: - 位置

    /// 刻み 25(0〜100)のスライダーを位置で合わせる。位置 p の値は 25 刻みに丸められる
    private func steppedValue(_ p: Double) -> String { "\(Int((p * 4).rounded()) * 25)%" }

    func testPositionReachesASteppedValue() async throws {
        var probes: [Double] = []
        let outcome = try await SliderValueLoop.byPosition(start: (0.5, "50%"), wanted: 75, resolution: 1.0 / 370) { p in
            probes.append(p)
            return self.steppedValue(p)
        }
        XCTAssertEqual(outcome.value, "75%")
        XCTAssertEqual(probes.first, 1, "目当ての側の端を先に読む")
        XCTAssertLessThanOrEqual(probes.count, 3, "\(probes)")
    }

    /// 刻みが目当てを飛ばすなら、1pt より狭くなる前に止まって間の値が無いことを言う(回数を数えずに終わる)
    func testPositionStopsWhenNoPositionGivesTheValue() async throws {
        var probes = 0
        do {
            _ = try await SliderValueLoop.byPosition(start: (0.5, "50%"), wanted: 60, resolution: 1.0 / 370) { p in
                probes += 1
                return self.steppedValue(p)
            }
            XCTFail("通った")
        } catch let failure as SliderValueLoop.Failure {
            XCTAssertTrue(failure.description.contains("nothing in between"), failure.description)
            XCTAssertLessThan(probes, 20, "1pt の幅で止まっていない")
        }
    }

    /// 刻みの無いスライダーは比例配分で1回で当たる
    func testPositionHitsAContinuousValueByInterpolation() async throws {
        var probes = 0
        let outcome = try await SliderValueLoop.byPosition(start: (0.2, "20.0"), wanted: 60, resolution: 1.0 / 370) { p in
            probes += 1
            return String(format: "%.1f", p * 100)
        }
        XCTAssertEqual(outcome.value, "60.0")
        XCTAssertEqual(probes, 2)
    }

    /// 範囲の外は端を読んだところで止まる
    func testPositionOutOfRangeStops() async throws {
        do {
            _ = try await SliderValueLoop.byPosition(start: (0.5, "50%"), wanted: 120, resolution: 1.0 / 370) { p in
                self.steppedValue(p)
            }
            XCTFail("通った")
        } catch let failure as SliderValueLoop.Failure {
            XCTAssertTrue(failure.description.contains("outside"), failure.description)
        }
    }

    // MARK: - どれを動かすか

    private func el(_ ref: Int, _ type: String, id: String? = nil, label: String? = nil, value: String? = nil,
                    x: Double = 0, width: Double = 400, depth: Int = 1) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: value, placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: 100, width: width, height: 48), depth: depth)
    }

    /// Flutter の Android: id は外側の入れ物、スライダーは子(値はラベル)
    func testContainerWithOneSliderMovesTheInnerSlider() {
        let container = el(1, "other", id: "slider_volume")
        let inner = el(2, "slider", label: "50%", x: 180, width: 48, depth: 2)
        guard case .target(let target) = SliderTarget.resolve(container, in: [container, inner]) else {
            return XCTFail("寄せなかった")
        }
        XCTAssertEqual(target.ref, 2)
        XCTAssertEqual(SliderTarget.currentValue(target), "50%")
    }

    /// 範囲スライダー(つまみ2つ)は撃たずに断る
    func testContainerWithTwoSlidersIsAmbiguous() {
        let container = el(1, "other", id: "range")
        let low = el(2, "slider", value: "20", x: 10, width: 48, depth: 2)
        let high = el(3, "slider", value: "80", x: 300, width: 48, depth: 2)
        guard case .ambiguous(let count) = SliderTarget.resolve(container, in: [container, low, high]) else {
            return XCTFail("断らなかった")
        }
        XCTAssertEqual(count, 2)
    }

    /// 子にスライダーが無ければそのまま(iOS の Compose・RN は other。調整できるかはブリッジが決める)
    func testOtherWithoutInnerSliderIsPassedAsIs() {
        let element = el(1, "other", id: "slider_volume", value: "50.0")
        guard case .target(let target) = SliderTarget.resolve(element, in: [element]) else { return XCTFail() }
        XCTAssertEqual(target.ref, 1)
        XCTAssertEqual(SliderTarget.currentValue(target), "50.0")
        // slider でない要素のラベルは値として読まない(ボタンのラベル等を値と取り違えない)
        XCTAssertNil(SliderTarget.currentValue(el(2, "other", label: "音量")))
    }

    // MARK: - 撃てなかった・木の親子に頼らない・タップで合わせる

    /// ブリッジが1段目を撃てなかったら、持っている操作を運んで止まる(Android の自前の View = 実測)
    func testNotPerformedCarriesTheNodesActions() async throws {
        do {
            _ = try await SliderValueLoop.byStepping(start: "50", wanted: 75) { _ in
                SliderStepResult(performed: false, value: "50", actions: ["ACTION_FOCUS - null"])
            }
            XCTFail("通った")
        } catch let failure as SliderValueLoop.Failure {
            guard case .notPerformed = failure else { return XCTFail("\(failure)") }
            XCTAssertTrue(failure.description.contains("ACTION_FOCUS"), failure.description)
        }
    }

    /// 1段目で値が動かなければ別の経路へ回せるように分けて言う(iOS の in-app で SwiftUI・RN の自前の View = 実測)
    func testFirstStepThatDoesNotMoveIsReportedSeparately() async throws {
        do {
            _ = try await SliderValueLoop.byStepping(start: "50%", wanted: 75) { _ in
                SliderStepResult(performed: true, value: "50%")
            }
            XCTFail("通った")
        } catch let failure as SliderValueLoop.Failure {
            guard case .firstStepDidNotMove = failure else { return XCTFail("\(failure)") }
        }
    }

    /// iOS の in-app の Flutter: 入れ物と中のスライダーが親子で並ばない(同じ深さ)。枠の中のスライダーちょうど1つへ寄せる
    func testInnerSliderIsFoundByItsFrameWhenTheTreeDoesNotNestIt() {
        let container = el(1, "other", id: "slider_volume", x: 16, width: 370)
        let inner = el(2, "slider", value: "50%", x: 177, width: 48, depth: 1)
        guard case .target(let target) = SliderTarget.resolve(container, in: [container, inner]) else {
            return XCTFail("寄せなかった")
        }
        XCTAssertEqual(target.ref, 2)
    }

    /// 帯の上のタップで合わせる: タップした位置の値が木に出る作り(25 刻み)。撃つ x は枠の中、値は撮り直した木から読む
    func testTapPositionSetsAJumpingSlider() async throws {
        let log = CallLog()
        let frame = FTRect(x: 16, y: 473, width: 370, height: 44)
        func tree(_ value: Int) -> [ElementInfo] {
            [ElementInfo(ref: 1, type: "other", identifier: "slider_volume", label: nil, value: "\(value)%", placeholder: nil,
                         enabled: true, frame: frame, depth: 1)]
        }
        let driver = FakeAppDriver(name: "d", log: log, snapshotElements: [tree(50)])
        driver.afterCoordinateTap = { [unowned driver] in
            let x = driver.coordinateTaps.last!.x
            let stepped = Int(((x - frame.x) / frame.width * 4).rounded()) * 25
            driver.snapshotElements = [tree(min(100, max(0, stepped)))]
        }
        let outcome = try await SliderTapPosition.set(driver: driver, frame: frame, area: frame,
                                                      identifier: "slider_volume", current: "50%", wanted: 75)
        XCTAssertEqual(outcome.value, "75%")
        XCTAssertTrue(driver.coordinateTaps.allSatisfy { $0.x > frame.x && $0.x < frame.x + frame.width && $0.y == frame.centerY },
                      "\(driver.coordinateTaps)")
    }

    /// タップで値が変わらない(つまみを引かないと動かない UISlider)なら、範囲の外として止まる(回数を数えずに終わる)
    func testTapPositionStopsWhenTappingDoesNotMoveIt() async throws {
        let log = CallLog()
        let frame = FTRect(x: 16, y: 459, width: 370, height: 31)
        let still = [ElementInfo(ref: 1, type: "slider", identifier: "s", label: nil, value: "50%", placeholder: nil,
                                 enabled: true, frame: frame, depth: 1)]
        let driver = FakeAppDriver(name: "d", log: log, snapshotElements: [still])
        do {
            _ = try await SliderTapPosition.set(driver: driver, frame: frame, area: frame, identifier: "s", current: "50%", wanted: 75)
            XCTFail("通った")
        } catch let failure as SliderValueLoop.Failure {
            XCTAssertTrue(failure.description.contains("outside"), failure.description)
            XCTAssertEqual(driver.coordinateTaps.count, 2, "両端を読んだところで止まる")
        }
    }

    /// 値が木に出ないスライダー(iOS の XCUITest の木の Flutter)は1回もタップせずに断る
    func testTapPositionRefusesWithoutTappingWhenTheValueIsUnreadable() async throws {
        let log = CallLog()
        let frame = FTRect(x: 16, y: 494, width: 370, height: 48)
        let driver = FakeAppDriver(name: "d", log: log, snapshotElements: [])
        do {
            _ = try await SliderTapPosition.set(driver: driver, frame: frame, area: frame, identifier: "slider_volume",
                                                current: nil, wanted: 75)
            XCTFail("通った")
        } catch let failure as SliderValueLoop.Failure {
            XCTAssertTrue(failure.description.contains("nothing was tapped"), failure.description)
        }
        XCTAssertTrue(driver.coordinateTaps.isEmpty, "\(driver.coordinateTaps)")
    }
}

