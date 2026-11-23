// Whether a dispatch that ended abnormally (timeout, ssh disconnect, or a non-normal sub-run
// exit code at the fan-out parent) may release the remote dispatch.lock depends on whether the
// run it started has actually ended on the runner — checked live over ssh. That can't be driven
// by a normal unit test without a real runner, so — same technique as
// RemoteDispatchLockInterruptRelayTests.swift / RemoteDispatchLockWaitLoopTests.swift — these
// tests pin the source shape: an unconditional release must not be reachable from a
// timeout/disconnect/non-normal-exit path; only the "release if the run has ended" judgment
// (`releaseLockIfRunEnded` / `liveDispatchedRunPIDs`) may release in those cases. Substring order
// checks are used instead of exact multi-line literals so continuation-line indentation can't
// make this brittle.

@testable import fleetest
import Foundation
import XCTest

final class RemoteDispatchLockConditionalReleaseTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FleetestTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリルート
    }

    private static func source() throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/fleetest/RemoteRunDispatcher.swift"),
            encoding: .utf8)
    }

    /// `marker` で始まる関数の本体(次の4スペース字下げの閉じ括弧まで)
    private static func functionBody(_ marker: String, in source: String) -> Substring? {
        guard let start = source.range(of: marker),
              let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex)
        else { return nil }
        return source[start.lowerBound..<end.upperBound]
    }

    /// 入口(dispatch / dispatchApi)は共通本体 performDispatch を呼ぶ。呼ばない入口は自前の本体を持ち、
    /// 共通本体の守り(catch → releaseLockIfRunEnded → rethrow・戻り値の捕捉)を通らない
    func testBothDispatchEntryPointsCallThePerformDispatchBody() throws {
        let source = try Self.source()
        for marker in ["func dispatch(", "func dispatchApi("] {
            guard let body = Self.functionBody(marker, in: source) else {
                XCTFail("\(marker) not found"); continue
            }
            XCTAssertTrue(body.contains("try await performDispatch("),
                          "\(marker): must delegate to performDispatch — the shared body holds the"
                          + " conditional-release guards")
        }
    }

    /// timeout(`runRemoteAndRelay` の throw)は catch して `releaseLockIfRunEnded` を経由してから
    /// rethrow する ―― 素通しで defer の無条件解放に落とさない
    func testSharedDispatchBodyCatchesRunRemoteAndRelayAndChecksIfTheRunEndedBeforeRethrowing() throws {
        let source = try Self.source()
        for marker in ["private func performDispatch("] {
            guard let body = Self.functionBody(marker, in: source) else {
                XCTFail("\(marker) not found"); continue
            }
            guard let callRange = body.range(of: "exitCode = try runRemoteAndRelay(") else {
                XCTFail("\(marker): runRemoteAndRelay call not found"); continue
            }
            guard let catchRange = body.range(of: "} catch {") else {
                XCTFail("\(marker): no catch around runRemoteAndRelay — a timeout throws past"
                        + " everything straight to the unconditional defer release")
                continue
            }
            guard let releaseIfEndedRange = body.range(of: "releaseLockIfRunEnded(layout: layout, reportDir: remoteReportDir)")
            else { XCTFail("\(marker): releaseLockIfRunEnded not called"); continue }
            guard let rethrowRange = body.range(of: "throw error") else {
                XCTFail("\(marker): no rethrow after the catch"); continue
            }
            XCTAssertTrue(callRange.upperBound < catchRange.lowerBound
                         && catchRange.upperBound < releaseIfEndedRange.lowerBound
                         && releaseIfEndedRange.upperBound < rethrowRange.lowerBound,
                         "\(marker): must be catch(runRemoteAndRelay) -> releaseLockIfRunEnded ->"
                         + " rethrow, in that order")
        }
    }

    /// `awaitRemoteRunEnd` はロックの行き先(`LockDisposition`)を返し、`releaseLockIfRunEnded` を自分で呼ぶ。
    /// 呼び出し側(共通本体 performDispatch)は戻り値を `lockDisposition` へ捕まえること
    func testAwaitRemoteRunEndIfDisconnectedReturnsBoolAndReleasesConditionally() throws {
        let source = try Self.source()
        guard let funcRange = source.range(of: "private func awaitRemoteRunEnd(")
        else { return XCTFail("function not found") }
        let body = source[funcRange.lowerBound...]
        guard let signatureEnd = body.range(of: "-> LockDisposition {") else {
            return XCTFail("awaitRemoteRunEnd must return LockDisposition —"
                          + " the caller needs to know whether it may skip the unconditional"
                          + " defer release")
        }
        guard let paramsRange = body.range(of: "layout: RemoteLayout,") else {
            return XCTFail("awaitRemoteRunEnd must take layout (needed to call"
                          + " releaseLockIfRunEnded)")
        }
        XCTAssertTrue(paramsRange.upperBound < signatureEnd.lowerBound)
        guard let releaseRange = body.range(of: "releaseLockIfRunEnded(layout: layout, reportDir: reportDir)")
        else {
            return XCTFail("the function must call releaseLockIfRunEnded instead of only logging"
                          + " and leaving the lock untouched")
        }
        XCTAssertTrue(signatureEnd.upperBound < releaseRange.lowerBound)

        for marker in ["private func performDispatch("] {
            guard let callerBody = Self.functionBody(marker, in: source) else {
                XCTFail("\(marker) not found"); continue
            }
            guard let assignRange = callerBody.range(of: "lockDisposition = awaitRemoteRunEnd(")
            else {
                XCTFail("\(marker): must capture awaitRemoteRunEnd's return value"
                        + " into lockDisposition — otherwise the unconditional defer release"
                        + " still fires underneath it")
                continue
            }
            _ = assignRange  // 存在確認のみ(継続行のインデントは崩れやすいので厳密比較しない)
        }
    }

    /// 親(fan-out)の解放は exitCode を受け取り、0/1(正常終了)以外は
    /// `liveDispatchedRunPIDs` で生死を確かめてから外す(無条件の releaseDispatchLock へ
    /// 素通ししない)
    func testReleaseDispatchLockAsParentChecksLivePIDsForNonNormalExitCodes() throws {
        let source = try Self.source()
        guard let funcRange = source.range(of: "func releaseDispatchLockAsParent(layout: RemoteLayout, exitCode: Int32?) {")
        else {
            return XCTFail("releaseDispatchLockAsParent(layout:exitCode:) not found — the parent"
                          + " release must take the sub-run's exit code")
        }
        let body = source[funcRange.lowerBound...]
        // 次の宣言(func/private func のどちらか)までをこの関数の本文とみなす
        let boundary = ["\n    func ", "\n    private func "]
            .compactMap { body.dropFirst(1).range(of: $0)?.lowerBound }
            .min() ?? body.endIndex
        let ownBody = body[body.startIndex..<boundary]
        guard let normalCheckRange = ownBody.range(of: "exitCode == 0 || exitCode == 1") else {
            return XCTFail("must special-case exactly the normal exit codes (0/1) — treating nil"
                          + " (unknown) as normal would release a lock whose sub-run's fate is"
                          + " unknown")
        }
        guard let livePIDsRange = ownBody.range(of: "liveDispatchedRunPIDs(layout: layout)") else {
            return XCTFail("the non-normal branch must consult liveDispatchedRunPIDs before releasing")
        }
        XCTAssertTrue(normalCheckRange.upperBound < livePIDsRange.lowerBound,
                      "liveDispatchedRunPIDs must be checked inside the non-normal-exit-code branch")
    }

    /// defer が外すのは「未決定」だけ。「残す」と判断したロックを関数末尾で外すと、後始末中の run に次の run が重なる
    func testExitReleasesOnlyUndecidedLock() {
        XCTAssertTrue(RemoteRunDispatcher.LockDisposition.undecided.releasesAtExit)
        XCTAssertFalse(RemoteRunDispatcher.LockDisposition.kept.releasesAtExit)
        XCTAssertFalse(RemoteRunDispatcher.LockDisposition.releasedEarly.releasesAtExit)
    }

    /// 「残す」の経路(打ち切りの catch・run の終わりの待ち)は `.kept` を立てる。立てずに Bool の false 等で
    /// 表すと defer の解放に落ちる
    func testKeptPathsSetKeptDisposition() throws {
        let source = try Self.source()
        guard let body = Self.functionBody("private func performDispatch(", in: source) else {
            return XCTFail("performDispatch not found")
        }
        XCTAssertTrue(body.contains("defer { if lockDisposition.releasesAtExit { releaseDispatchLock(layout: layout) } }"))
        guard let catchRange = body.range(of: "} catch {"),
              let keptRange = body.range(of: "lockDisposition = .kept", range: catchRange.upperBound..<body.endIndex)
        else { return XCTFail("the timeout catch must set lockDisposition = .kept when the lock is not released") }
        _ = keptRange
        guard let awaitBody = Self.functionBody("private func awaitRemoteRunEnd(", in: source) else {
            return XCTFail("awaitRemoteRunEnd not found")
        }
        XCTAssertTrue(awaitBody.contains("return .kept"),
                      "awaitRemoteRunEnd must return .kept when releaseLockIfRunEnded could not release")
    }

    /// 中断したら exit 0/1 でも待つ(ssh は即座に閉じるが向こうは後始末中 = 待たないと開始欄だけを回収する)。
    /// 中断していない exit 0/1 は待たない(正常終了は run.json を書き終えてから exit している)
    func testShouldAwaitRemoteRunEndWaitsOnInterruptionEvenForNormalExitCodes() {
        XCTAssertTrue(RemoteRunDispatcher.shouldAwaitRemoteRunEnd(exitCode: 0, interrupted: true))
        XCTAssertTrue(RemoteRunDispatcher.shouldAwaitRemoteRunEnd(exitCode: 1, interrupted: true))
        XCTAssertTrue(RemoteRunDispatcher.shouldAwaitRemoteRunEnd(exitCode: 255, interrupted: false))
        XCTAssertFalse(RemoteRunDispatcher.shouldAwaitRemoteRunEnd(exitCode: 0, interrupted: false))
        XCTAssertFalse(RemoteRunDispatcher.shouldAwaitRemoteRunEnd(exitCode: 1, interrupted: false))
    }
}
