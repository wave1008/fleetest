// `fleetest run --profile` と `fleetest api run` が RunOrchestrator の配線を ProfileRunOrchestrator の
// 1箇所から受けることを固定する。**型では守れない継ぎ目**: どちらかが RunOrchestrator を直に組み直すと、
// 配線を見る走査(RunProgressLedgerWiringTests / SupplyLeaseHandOffWiringTests / RunnerMidRunRecheckTests)は
// 共有ファイルだけを見て緑のまま、その経路だけ lease・進捗・再確認が抜ける。

import XCTest

final class ProfileRunOrchestratorWiringTests: XCTestCase {

    private static let callers = ["Sources/fleetest/ProfileRunner.swift",
                                  "Sources/fleetest/ApiRunCommand.swift"]

    private static func codeWithoutComments(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    func testBothRunPathsBuildTheOrchestratorThroughTheSharedWiring() throws {
        for path in Self.callers {
            let text = try Self.codeWithoutComments(path)
            XCTAssertEqual(count("ProfileRunOrchestrator.make(", in: text), 1, path)
            XCTAssertEqual(count("RunOrchestrator(", in: text), 0,
                           "\(path) が RunOrchestrator を直に組んでいる(共有の配線を迂回する)")
            XCTAssertEqual(count("ProfileRunOrchestrator.writePreparingProgress(", in: text), 1,
                           "\(path) が供給の前に段階「準備中」を書いていない")
        }
    }

    /// 供給で合流しなかった台を DR-214 の「落ちた台」へ記帳する配線。宣言したデバイスの一覧を渡さないと、
    /// 合流できなかった台が居ない扱いになり、全部が別の台で対象外 = 0 本実行の緑になる
    func testPlannedLanesAreHandedToTheOrchestratorAndRegisteredAfterSupply() throws {
        let make = try Self.codeWithoutComments("Sources/fleetest/ProfileRunOrchestrator.swift")
        XCTAssertEqual(count("plannedLanes: resolved.devices.map", in: make), 1)
        let orchestrator = try Self.codeWithoutComments("Sources/FTCore/RunOrchestrator.swift")
        XCTAssertEqual(count("await Self.registerNeverJoined(", in: orchestrator), 2,
                       "初期ワーカーの前と遅延参加の合流の前の2箇所で記帳する")
        XCTAssertEqual(count("await queues[entry.platform]?.laneNeverJoined(entry.lane, traits: traits[entry.lane])", in: orchestrator), 1)
        XCTAssertEqual(count("plannedTraits: plannedTraits,", in: make), 1, "台の性質を渡さないと、合う台の欠落が緑の対象外に化ける")
        XCTAssertEqual(count("traits: plannedTraits)", in: orchestrator), 2)
    }
}
