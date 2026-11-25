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
    }

    func testWaitIsPinned() {
        XCTAssertEqual(SimulatorAppearanceArbiter.reactionWaitSeconds, 1)
    }

    /// 呼ばれたコマンドの記録と、反応の有無を決める偽の実行
    private final class Fake {
        var calls: [[String]] = []
        var reacts: [Bool]
        var restarts = 0
        init(reacts: [Bool]) { self.reacts = reacts }
        func run(_ args: [String], _ timeout: Double) throws -> Shell.Result {
            calls.append(args)
            if args == ["xcrun", "simctl", "ui", "U", "appearance"] { return Shell.Result(status: 0, output: "light\n") }
            if args.contains("log") {
                if args.last?.contains("forReason:0") == true {
                    return Shell.Result(status: 0, output: "x [com.apple.UIKit:UserInterfaceStyleArbiter] forReason:0\n")
                }
                let reacted = reacts.isEmpty ? false : reacts.removeFirst()
                return Shell.Result(status: 0, output: reacted
                    ? "x [com.apple.UIKit:UserInterfaceStyleArbiter] Arbiter changing style from 1 to 2\n" : "Timestamp\n")
            }
            return Shell.Result(status: 0, output: "")
        }
    }

    private func check(_ fake: Fake) -> SimulatorAppearanceArbiter.Verdict {
        SimulatorAppearanceArbiter.ensureResponsive(
            udid: "U", log: { _ in }, run: fake.run, restart: { _ in fake.restarts += 1; return (true, "") },
            now: Date.init, sleep: { _ in })
    }

    func testResponsiveDoesNotRestartAndRestoresTheAppearance() {
        let fake = Fake(reacts: [true])
        XCTAssertEqual(check(fake), .responsive)
        XCTAssertEqual(fake.restarts, 0)
        let sets = fake.calls.filter { $0.count == 6 && $0[4] == "appearance" }.map { $0[5] }
        XCTAssertEqual(sets, ["dark", "light"], "反対へ変えて元へ戻す")
    }

    func testSilentArbiterRestartsSpringBoardOnce() {
        let fake = Fake(reacts: [false, true])
        XCTAssertEqual(check(fake), .restarted(responsiveAfter: true))
        XCTAssertEqual(fake.restarts, 1)
        let stillSilent = Fake(reacts: [false, false])
        XCTAssertEqual(check(stillSilent), .restarted(responsiveAfter: false))
        XCTAssertEqual(stillSilent.restarts, 1, "起こし直しは1回だけ")
    }

    /// 外観が読めなければ何もしない(起こし直さない)
    func testUnreadableAppearanceDoesNothing() {
        let verdict = SimulatorAppearanceArbiter.ensureResponsive(
            udid: "U", log: { _ in }, run: { _, _ in Shell.Result(status: 1, output: "") },
            restart: { _ in XCTFail("起こし直した"); return (true, "") }, now: Date.init, sleep: { _ in })
        guard case .unchecked = verdict else { return XCTFail("\(verdict)") }
    }
}
