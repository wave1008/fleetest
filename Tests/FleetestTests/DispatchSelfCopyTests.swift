// DispatchSelfCopy の純粋部分と、2実装(run / api run)の配線。コピーへの exec そのものはデバイス実行の陽性対照で確かめる
// (リモートで回している最中に手元で fleetest を作り直し、run が最後まで走ること)。

import Foundation
import XCTest
@testable import fleetest

final class DispatchSelfCopyTests: XCTestCase {
    func testOnlyBuildProductsAreCopied() {
        XCTAssertTrue(DispatchSelfCopy.isUnderBuildDirectory("/r/fleetest-mobile/.build/out/Products/Debug/fleetest"))
        XCTAssertTrue(DispatchSelfCopy.isUnderBuildDirectory("/r/fleetest-mobile/.build/debug/fleetest"))
        XCTAssertFalse(DispatchSelfCopy.isUnderBuildDirectory("/usr/local/bin/fleetest"))
        XCTAssertFalse(DispatchSelfCopy.isUnderBuildDirectory("/tmp/fleetest-dispatch-123/fleetest"))
    }

    func testSweepRemovesOnlyDirectoriesOfDeadOwners() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("self-copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        for name in ["fleetest-dispatch-111", "fleetest-dispatch-222", "fleetest-dispatch-abc", "other-333"] {
            try FileManager.default.createDirectory(at: base.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        DispatchSelfCopy.sweepAbandoned(in: base, isAlive: { $0 == 222 })
        let left = try FileManager.default.contentsOfDirectory(atPath: base.path).sorted()
        XCTAssertEqual(left, ["fleetest-dispatch-222", "fleetest-dispatch-abc", "other-333"])
    }

    /// コピーへ移るのは**単一のリモートへの分岐の中だけ**・`--work-queue` の子では移らない、を両コマンドで固定する。
    /// 手元の run で移ると、隣のヘルパーと手元のシナリオ実行バイナリが見つからなくなる。
    /// work-queue の子で移ると、入口で close-on-exec へ移した stdin(親からの返事)が exec で消える
    func testBothCommandsCopyOnlyOnTheSingleRemoteBranch() throws {
        let call = "if !common.workQueue { DispatchSelfCopy.reexecIfNeeded("
        let cases = [
            ("Sources/fleetest/Fleetest.swift", "try await dispatchToRemoteHost(dispatch)\n"),
            ("Sources/fleetest/ApiRunCommand.swift", "try await dispatchToRemoteHost(dispatch, project: testProject)\n"),
        ]
        for (file, dispatchCall) in cases {
            let text = try String(contentsOf: Self.repoRoot.appendingPathComponent(file), encoding: .utf8)
            XCTAssertEqual(text.components(separatedBy: "DispatchSelfCopy.").count - 1, 1,
                           "\(file): DispatchSelfCopy must be called exactly once")
            let branch = try XCTUnwrap(text.range(of: "resolveEffectiveDispatchTarget("), file)
            let dispatch = try XCTUnwrap(text.range(of: dispatchCall, range: branch.upperBound..<text.endIndex), file)
            XCTAssertTrue(text[branch.upperBound..<dispatch.lowerBound].contains(call),
                          "\(file): copy the relay (guarded by !common.workQueue) right before the single remote dispatch")
        }
    }

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}
