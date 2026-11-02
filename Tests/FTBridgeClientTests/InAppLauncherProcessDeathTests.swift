// 注入起動したアプリが ready の前に死んだら、30 秒待ち切らずに notReady で早く返す。
// 死は launchd の事実(appIsRunning == false)が連続して確定したときだけ。判定できない(nil)・生きている間は待ち続ける。

import XCTest
@testable import FTBridgeClient

final class InAppLauncherProcessDeathTests: XCTestCase {
    private func launcher() -> InAppLauncher {
        // ポート 1 は誰も待ち受けない(接続拒否)= ブリッジは応答しない
        InAppLauncher(repoRoot: URL(fileURLWithPath: "/nonexistent"), udid: "TEST", port: 1)
    }

    func testReturnsEarlyWhenTheProcessIsGone() async {
        let started = Date()
        do {
            try await launcher().waitUntilReady(timeout: 20, appIsRunning: { false })
            XCTFail("notReady を期待")
        } catch let InAppLauncherError.notReady(detail) {
            XCTAssertEqual(detail, InAppLauncher.appExitedDetail)
        } catch { XCTFail("\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "30 秒の待ちを使い切らないこと")
    }

    /// 1 回だけの「居ない」では確定しない(起こし直しの瞬間の入れ替わり)。生きている答えで数え直す
    func testASingleGoneAnswerDoesNotConfirmDeath() async {
        let answers = LockedAnswers([false, true, false, true, false, true, false, true])
        let started = Date()
        do {
            try await launcher().waitUntilReady(timeout: 3.5, appIsRunning: { answers.next() })
            XCTFail("notReady を期待")
        } catch let InAppLauncherError.notReady(detail) {
            XCTAssertNotEqual(detail, InAppLauncher.appExitedDetail, "交互の答えで死と確定してはいけない")
        } catch { XCTFail("\(error)") }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 3, "期限まで待つこと")
    }

    /// 判定できない(nil)は死ではない
    func testUnknownAnswerKeepsWaiting() async {
        let started = Date()
        do {
            try await launcher().waitUntilReady(timeout: 3, appIsRunning: { nil })
            XCTFail("notReady を期待")
        } catch let InAppLauncherError.notReady(detail) {
            XCTAssertNotEqual(detail, InAppLauncher.appExitedDetail)
        } catch { XCTFail("\(error)") }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 2.9)
    }
}

private final class LockedAnswers: @unchecked Sendable {
    // 不変条件: answers / index は lock の中でだけ触る
    private let lock = NSLock()
    private var answers: [Bool]
    private var index = 0
    init(_ answers: [Bool]) { self.answers = answers }
    func next() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let value = answers[min(index, answers.count - 1)]
        index += 1
        return value
    }
}
