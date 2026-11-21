// beforeRun / afterRun(RR-8.4)の配線。判断は FTCore の `RunWideHookPlan` の1箇所で、各経路は結果を写すだけ。
// 経路が増減・脱落したら(片方の実装にだけ足して他方を忘れる = `run` と `api run` の2実装の罠)ここで落とす。

import Foundation
import XCTest

final class RunHookWiringTests: XCTestCase {
    private var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
    }

    func testMachineSpanningParentsHoldTheStartGateUntilBeforeRunDecides() throws {
        for path in ["fleetest/DeviceMachineRunner.swift", "fleetest/ApiRunMachineFanout.swift"] {
            let body = try text(path)
            XCTAssertTrue(body.contains("RunWideHookPlan.hooksClassToRun("), path)
            XCTAssertTrue(body.contains("gateMode: hookParent == nil ? .startOnHello : .awaitDecision"), path)
            XCTAssertTrue(body.contains("hookParent?.start(hub: memoRelay.hub)"), path)
            XCTAssertTrue(body.contains("hookParent.finish(hub: memoRelay.hub"), path)
            XCTAssertTrue(body.contains("beforeRunFailed"), "\(path): beforeRun の失敗は配れなかった分・結果の無い分を失敗に数えない")
        }
        let multi = try text("fleetest/MultiTargetRunner.swift")
        XCTAssertTrue(multi.contains(".awaitDecision"), "複数対象の親が beforeRun の結果まで開始を保留していない")
        XCTAssertTrue(multi.contains("hook.startBeforeRunIfNeeded()"))
        XCTAssertTrue(multi.contains("hook.parent.finish("))
        XCTAssertTrue(multi.contains("hook.parent.beforeRunFailed"), "失敗したプロジェクトの対象を以後起こさない判断が無い")
    }

    /// afterRun はロックを持ったまま(`prelock.releaseAll` の前)・親は子を起こす前の `ParentLink.isLinked` を `linkedToParent:` へ渡す
    func testAfterRunRunsBeforeTheLocksAreReleasedAndLinkedChildrenNeverRunHooks() throws {
        for (path, finish) in [("fleetest/DeviceMachineRunner.swift", "hookParent.finish("),
                               ("fleetest/ApiRunMachineFanout.swift", "hookParent.finish("),
                               ("fleetest/MultiTargetRunner.swift", "hook.parent.finish(")] {
            let body = try text(path)
            let finishAt = try XCTUnwrap(body.range(of: finish), path)
            let releaseAt = try XCTUnwrap(body.range(of: "prelock.releaseAll("), path)
            XCTAssertLessThan(finishAt.lowerBound, releaseAt.lowerBound, "\(path): afterRun をロックの解放より後に撃っている")
            XCTAssertTrue(body.contains("linkedToParent: ParentLink.isLinked"), "\(path): 親とつながった子が走らせない判定を渡していない")
        }
        XCTAssertTrue(try text("fleetest/RunHookParent.swift").contains("linkedToParent: ParentLink.isLinked"))
    }

    /// afterRun を撃つ run が持ち続けるのは手元のロックだけ。リモートは子が終わり次第外す(全部の子の終わりまで持つと、先に終えた
    /// ランナー機が他の人の run を待たせる)。子ごとの解放を `hookParent == nil` だけで止める形へ戻すと落ちる
    func testOnlyTheLocalLockIsHeldUntilAfterRun() throws {
        for path in ["fleetest/DeviceMachineRunner.swift", "fleetest/ApiRunMachineFanout.swift"] {
            let body = try text(path)
            XCTAssertTrue(body.contains("if hookParent == nil || outcome.host != DeviceMachineGrouping.localDisplayName {\n"
                                        + "                    prelock.release(afterChildOf: outcome.host, exitCode: outcome.exitCode)"),
                          "\(path): リモートのロックまで afterRun の後まで持っている、または手元のロックを先に外している")
        }
    }

    /// 中継役の打ち切りは専用の終了コード(1 と取り違えると発行元が afterRun を撃つ)。dispatch と dispatchApi の2経路とも
    /// 共通本体 performDispatch を通り、その本体が返す
    func testRelayTimeoutEndsWithTheDedicatedExitCodeInBothDispatchPaths() throws {
        let body = try text("fleetest/RemoteRunDispatcher.swift")
        func functionBody(_ marker: String) throws -> Substring {
            let start = try XCTUnwrap(body.range(of: marker), marker)
            let end = try XCTUnwrap(body.range(of: "\n    }\n", range: start.upperBound..<body.endIndex), marker)
            return body[start.lowerBound..<end.upperBound]
        }
        for entry in ["func dispatch(", "func dispatchApi("] {
            XCTAssertTrue(try functionBody(entry).contains("try await performDispatch("),
                          "\(entry): 共通本体を通らない経路は打ち切りの終了コードを返せない")
        }
        XCTAssertEqual(try functionBody("private func performDispatch(")
            .components(separatedBy: "return RemoteDispatchExit.runUnconfirmed").count - 1, 1)
        XCTAssertEqual(body.components(separatedBy: "return RemoteDispatchExit.runUnconfirmed").count - 1, 1,
                       "共通本体の外に打ち切りの返し方が増えた")
        XCTAssertTrue(body.contains("RemoteDispatchError.remoteRunTimedOut("))
        XCTAssertFalse(body.contains("remote run timed out"), "打ち切りを remoteSetupFailed(終了コード 1)で投げている")
    }

    /// ProfileRunner は Android の供給の待ち・レーンの検査の後で beforeRun を撃つ。プロファイル無しの api run は走らせない(`run` と同じ)
    func testBeforeRunPositionAndProfilelessRunsDoNotRunHooks() throws {
        let profile = try text("fleetest/ProfileRunner.swift")
        let supplyWait = try XCTUnwrap(profile.range(of: "try await prepared.androidTask.value"))
        let begin = try XCTUnwrap(profile.range(of: "SingleMachineRunHooks.begin("))
        XCTAssertLessThan(supplyWait.lowerBound, begin.lowerBound)
        let api = try text("fleetest/ApiRunCommand.swift")
        XCTAssertEqual(api.components(separatedBy: "SingleMachineRunHooks.begin(").count - 1, 1, "runDirect に配線が残っている")
        XCTAssertTrue(api.contains("unsupportedModeLine(mode: \"a run without --profile\")"))
    }

    func testSingleMachineRunsAndMCPRunTheSameHooks() throws {
        for path in ["fleetest/ProfileRunner.swift", "fleetest/ApiRunCommand.swift"] {
            XCTAssertTrue(try text(path).contains("SingleMachineRunHooks.begin("), path)
            XCTAssertTrue(try text(path).contains("runHooks.finish("), path)
            XCTAssertTrue(try text(path).contains("seedRunMemo(runHooks.seedOps)"), path)
        }
        let mcp = try text("fleetest-mcp/MCPServer+ScenarioTools.swift")
        XCTAssertTrue(mcp.contains("RunWideHookPlan.hooksClassToRun("))
        XCTAssertTrue(mcp.contains("RunHookFlow.runBefore("))
        XCTAssertTrue(mcp.contains("RunHookFlow.finish("))
    }

    /// beforeRun の失敗を JUnit に載せる(1台の run は段階の失敗・マシンをまたぐ親は結合に足す)。経路を落とすと CI に理由が届かない
    func testBeforeRunFailureReachesTheJUnitReportOnEveryPath() throws {
        XCTAssertTrue(try text("fleetest/Fleetest.swift").contains(#"writeJUnitForEarlyFailure(project: testProject, phase: "beforeRun", reason: reason)"#))
        XCTAssertTrue(try text("fleetest/DeviceMachineRunner.swift").contains("beforeRunFailures: hookParent?.beforeRunFailureReason"))
        XCTAssertTrue(try text("fleetest/MultiTargetRunner.swift").contains("hook.parent.beforeRunFailureReason"))
    }

    func testFleetIsRefusedBeforeAnyEntryStarts() throws {
        let fleet = try text("fleetest/FleetRunner.swift")
        let refusal = try XCTUnwrap(fleet.range(of: "RunWideHookPlan.fleetRefusal"))
        let firstEntry = try XCTUnwrap(fleet.range(of: "DispatchTicketIssuer.issue("))
        XCTAssertLessThan(refusal.lowerBound, firstEntry.lowerBound, "--fleet の断りは最初のエントリを起こす前に置く")
    }

    func testHookDecisionsLiveOnlyInRunHookPlan() throws {
        // 経路側で条件を書き直さない(親とつながった子の判定を各所で持つと、経路ごとにずれる)
        for path in ["fleetest/DeviceMachineRunner.swift", "fleetest/ApiRunMachineFanout.swift", "fleetest/MultiTargetRunner.swift",
                     "fleetest/ProfileRunner.swift", "fleetest/ApiRunCommand.swift"] {
            XCTAssertFalse(try text(path).contains("afterRunVerdict("), "\(path): afterRun の条件は RunHookFlow.finish の中の1箇所")
        }
    }
}
