// 外観を届けない SpringBoard を、ランナーを起こす前に見つけて起こし直す(SimulatorAppearanceArbiter)
import XCTest
@testable import FTCore

final class SimulatorAppearanceArbiterTests: XCTestCase {
    private let arbiterLine = "2026-11-25 22:38:05.503 Df SpringBoard[10832:12d0b] [com.apple.UIKit:UserInterfaceStyleArbiter] Arbiter changing style from 1 to 2, notifying: 1"
    private let startLine = "2026-11-25 22:44:20.001 Df SpringBoard[93323:1] [com.apple.UIKit:UserInterfaceStyleArbiter] Arbiter _updateCurrentStyleAndNotify:1 forReason:0"

    func testParsing() {
        XCTAssertEqual(SimulatorAppearanceArbiter.parseAppearance("dark\n"), "dark")
        XCTAssertNil(SimulatorAppearanceArbiter.parseAppearance("unsupported"))
        XCTAssertTrue(SimulatorAppearanceArbiter.arbiterReacted("Timestamp\n" + arbiterLine))
        XCTAssertFalse(SimulatorAppearanceArbiter.arbiterReacted("Timestamp               Ty Process[PID:TID]\n"))
        XCTAssertTrue(SimulatorAppearanceArbiter.arbiterStarted(startLine))
        XCTAssertEqual(SimulatorAppearanceArbiter.springBoardPID("PID\tStatus\tLabel\n6624\t0\tcom.apple.SpringBoard\n7166\t0\tcom.apple.InputUI\n"), 6624)
        XCTAssertNil(SimulatorAppearanceArbiter.springBoardPID("-\t-5\tcom.apple.SpringBoard\n"))
    }

    /// 既定値はリテラルで固定する(根拠は本体の doc)
    func testWaitsArePinned() {
        XCTAssertEqual(SimulatorAppearanceArbiter.reactionWaitSeconds, 1)
        XCTAssertEqual(SimulatorAppearanceArbiter.arbiterStartWaitSeconds, 30)
        XCTAssertEqual(SimulatorAppearanceArbiter.startLookbackHours, 24)
    }

    /// 呼ばれたコマンドの記録と、反応の有無を決める偽の実行
    private final class Fake {
        var calls: [[String]] = []
        var reacts: [Bool]
        var started: Bool
        var restarts = 0
        var pid = 100
        init(reacts: [Bool], started: Bool = true) { self.reacts = reacts; self.started = started }
        func run(_ args: [String], _ timeout: Double) throws -> Shell.Result {
            calls.append(args)
            if args.suffix(2) == ["launchctl", "list"] {
                return Shell.Result(status: 0, output: "PID\tStatus\tLabel\n\(pid)\t0\tcom.apple.SpringBoard\n")
            }
            if args == ["xcrun", "simctl", "ui", "U", "appearance"] { return Shell.Result(status: 0, output: "light\n") }
            if args.contains("log") {
                XCTAssertTrue(args.last?.hasPrefix("processID == \(pid) ") == true, "今の SpringBoard の pid で絞る: \(args)")
                if args.last?.contains("forReason:0") == true {
                    return Shell.Result(status: 0, output: started ? "x [com.apple.UIKit:UserInterfaceStyleArbiter] forReason:0\n" : "Timestamp\n")
                }
                let reacted = reacts.isEmpty ? false : reacts.removeFirst()
                return Shell.Result(status: 0, output: reacted
                    ? "x [com.apple.UIKit:UserInterfaceStyleArbiter] Arbiter changing style from 1 to 2\n" : "Timestamp\n")
            }
            return Shell.Result(status: 0, output: "")
        }
    }

    /// 偽の時計(sleep で進む)。起動の行を待つ上限を実時間で待たない
    private final class Clock {
        var t = Date(timeIntervalSince1970: 0)
        func now() -> Date { t }
        func sleep(_ s: Double) { t = t.addingTimeInterval(s) }
    }

    private func check(_ fake: Fake, restartAllowed: Bool = true) -> SimulatorAppearanceArbiter.Verdict {
        let clock = Clock()
        return SimulatorAppearanceArbiter.ensureResponsive(
            udid: "U", restartAllowed: restartAllowed, log: { _ in }, run: fake.run,
            restart: { _ in fake.restarts += 1; fake.pid += 1; return (true, "") },
            now: clock.now, sleep: clock.sleep)
    }

    func testResponsiveDoesNotRestartAndRestoresBeforeReadingTheLog() {
        let fake = Fake(reacts: [true])
        XCTAssertEqual(check(fake), .responsive)
        XCTAssertEqual(fake.restarts, 0)
        let sets = fake.calls.filter { $0.count == 6 && $0[4] == "appearance" }.map { $0[5] }
        XCTAssertEqual(sets, ["dark", "light"], "反対へ変えて元へ戻す")
        let restoreIndex = fake.calls.lastIndex { $0.count == 6 && $0[5] == "light" }!
        let reactionRead = fake.calls.lastIndex { $0.last?.contains("changing style") == true }!
        XCTAssertLessThan(restoreIndex, reactionRead, "元へ戻してからログを読む(変えたままの時間を短く)")
    }

    func testSilentArbiterRestartsSpringBoardOnceAndReadsTheNewPID() {
        let fake = Fake(reacts: [false, true])
        XCTAssertEqual(check(fake), .restarted(responsiveAfter: true))
        XCTAssertEqual(fake.restarts, 1)
        let stillSilent = Fake(reacts: [false, false])
        XCTAssertEqual(check(stillSilent), .restarted(responsiveAfter: false))
        XCTAssertEqual(stillSilent.restarts, 1, "起こし直しは1回だけ")
    }

    /// 同じ台のブリッジを使い回しうるなら起こし直さない
    func testRestartNotAllowedOnlyLogs() {
        let fake = Fake(reacts: [false])
        XCTAssertEqual(check(fake, restartAllowed: false), .unresponsiveNotRestarted)
        XCTAssertEqual(fake.restarts, 0)
    }

    /// 部品の起動の行が見えない(起動直後で立ち上がらない・OS の更新で文言が変わった)なら確かめない = 起こし直さない・外観も変えない
    func testUnseenArbiterIsUncheckedAndTouchesNothing() {
        let fake = Fake(reacts: [false], started: false)
        guard case .unchecked = check(fake) else { return XCTFail("確かめずに判断した") }
        XCTAssertEqual(fake.restarts, 0)
        XCTAssertFalse(fake.calls.contains { $0.count == 6 && $0[4] == "appearance" }, "外観を変えた")
    }

    /// 外観が読めなければ何もしない
    func testUnreadableAppearanceDoesNothing() {
        let clock = Clock()
        let verdict = SimulatorAppearanceArbiter.ensureResponsive(
            udid: "U", restartAllowed: true, log: { _ in },
            run: { args, _ in
                if args.suffix(2) == ["launchctl", "list"] { return Shell.Result(status: 0, output: "1\t0\tcom.apple.SpringBoard\n") }
                if args.contains("log") { return Shell.Result(status: 0, output: "x [com.apple.UIKit:UserInterfaceStyleArbiter] forReason:0\n") }
                return Shell.Result(status: 1, output: "")
            },
            restart: { _ in XCTFail("起こし直した"); return (true, "") }, now: clock.now, sleep: clock.sleep)
        guard case .unchecked = verdict else { return XCTFail("\(verdict)") }
    }
}
