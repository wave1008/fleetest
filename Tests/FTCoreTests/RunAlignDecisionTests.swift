// `run --align` が宛先のランナーを揃えてよいかの判定(RR-18.3 規則1 = この機械が古い・分岐しているときに
// ランナーを巻き戻さない)。純粋関数 `RemoteAlignPlan.runAlignDecision` を関係ごとに1件ずつ固定する。

import XCTest
import FTRemote

final class RunAlignDecisionTests: XCTestCase {
    private func remote(digest: String?) -> AlignSnapshot.RemoteToolState {
        AlignSnapshot.RemoteToolState(head: "h", digest: digest, base: "b", snapshotIssuer: nil, built: true)
    }

    private func decide(remote: AlignSnapshot.RemoteToolState?, relation: RevisionRelation,
                        asked: ((Bool) -> Void)? = nil) -> RemoteAlignPlan.RunAlignDecision {
        RemoteAlignPlan.runAlignDecision(localDigest: "L", remote: remote, relation: { _ in
            asked?(true)
            return relation
        })
    }

    func testRunnerCloneUnreadableProceeds() {
        XCTAssertEqual(decide(remote: nil, relation: .unknown), .proceed)
    }

    func testSameDigestProceedsWithoutAskingTheDirection() {
        var asked = false
        XCTAssertEqual(decide(remote: remote(digest: "L"), relation: .diverged, asked: { _ in asked = true }), .proceed)
        XCTAssertFalse(asked, "the direction costs git calls; it is only needed when the digests differ")
    }

    func testRemoteBehindProceeds() {
        XCTAssertEqual(decide(remote: remote(digest: "R"), relation: .remoteBehind), .proceed)
    }

    func testWorkingTreeDiffersProceeds() {
        XCTAssertEqual(decide(remote: remote(digest: "R"), relation: .workingTreeDiffers), .proceed)
    }

    func testLocalBehindRefuses() {
        XCTAssertEqual(decide(remote: remote(digest: "R"), relation: .localBehind), .refuse(.localBehind))
    }

    func testDivergedRefuses() {
        XCTAssertEqual(decide(remote: remote(digest: "R"), relation: .diverged), .refuse(.diverged))
    }

    func testUnknownRefuses() {
        XCTAssertEqual(decide(remote: remote(digest: "R"), relation: .unknown), .refuse(.unknown))
    }

    func testUnreadableRemoteDigestIsTreatedAsDifferentAndDecidedByDirection() {
        XCTAssertEqual(decide(remote: remote(digest: nil), relation: .localBehind), .refuse(.localBehind))
        XCTAssertEqual(decide(remote: remote(digest: nil), relation: .remoteBehind), .proceed)
    }

    func testToolRevSendLineNamesTheRevisionAndSaysTheWorkingTreeIsNotIncluded() {
        let line = RemoteAlignPlan.sendLine(toolRev: "HEAD~2", commit: "abcdef0123456")
        XCTAssertTrue(line.contains("HEAD~2") && line.contains("abcdef0") && line.contains("working tree is not included"), line)
    }
}
