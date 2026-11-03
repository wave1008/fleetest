// 要約が手元と同じでも、成功したビルドの記録が無い(未ビルド・ビルドの失敗・中断)ランナーを「一致」と言わない。
// 沈黙の誤り(古いバイナリのまま照合が通って緑)の砦。

import XCTest
import FTRemote

final class RemoteCompatUnbuiltTests: XCTestCase {
    private let local = RemoteCompat.LocalTool(head: "aaaaaaa1111", digest: "dg", isClean: true)

    private func verdict(built: Bool, digest: String = "dg") -> RemoteCompat.CompatVerdict {
        let remote = AlignSnapshot.RemoteToolState(head: "bbbbbbb2222", digest: digest, base: "bbbbbbb2222",
                                                   snapshotIssuer: nil, built: built)
        return RemoteCompat.verdict(local: local, remoteTool: remote, localToolchain: "t", remoteToolchain: "t")
    }

    /// 狙い: `appendRevision` の未ビルドの分岐を消す変異で落ちる / 常に blocking にする変異で built 側が落ちる
    func testUnbuiltRunnerBlocksEvenWhenTheDigestMatches() throws {
        XCTAssertTrue(verdict(built: true).isCompatible)
        let blocked = verdict(built: false)
        XCTAssertEqual(blocked.blocking.count, 1)
        let reason = try XCTUnwrap(blocked.blocking.first)
        XCTAssertTrue(reason.hasPrefix("git revision"), "HostReport.revisionCompatible picks blockers by this prefix")
        XCTAssertTrue(reason.contains("bbbbbbb"), reason)
        XCTAssertTrue(reason.contains("has no record of a successful align build"), reason)
        XCTAssertTrue(reason.contains("fleetest remote align"), reason)
    }

    /// 要約が違うときは従来の不一致の文言(向きの案内が付く側)で、未ビルドの文言にしない
    func testDigestMismatchKeepsTheMismatchWording() throws {
        let blocked = verdict(built: false, digest: "other")
        XCTAssertEqual(blocked.blocking.count, 1)
        let reason = try XCTUnwrap(blocked.blocking.first)
        XCTAssertTrue(reason.hasPrefix("git revision mismatch"), reason)
    }

    func testIsUnbuiltOnly() {
        func remote(_ built: Bool, _ digest: String) -> AlignSnapshot.RemoteToolState {
            AlignSnapshot.RemoteToolState(head: "h", digest: digest, base: "h", snapshotIssuer: nil, built: built)
        }
        XCTAssertTrue(RemoteCompat.isUnbuiltOnly(local: local, remote: remote(false, "dg")))
        XCTAssertFalse(RemoteCompat.isUnbuiltOnly(local: local, remote: remote(true, "dg")))
        XCTAssertFalse(RemoteCompat.isUnbuiltOnly(local: local, remote: remote(false, "other")))
        XCTAssertFalse(RemoteCompat.isUnbuiltOnly(local: nil, remote: remote(false, "dg")))
    }
}
