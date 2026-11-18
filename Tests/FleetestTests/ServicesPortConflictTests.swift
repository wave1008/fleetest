// 起動失敗に添える「同じホストポートを持つ別プロジェクトの生きた控え」の特定(純粋部分)。

import XCTest
import FTServices
@testable import fleetest

final class ServicesPortConflictTests: XCTestCase {
    private func lease(pid: Int32, prefix: String, project: String, kind: ServicesLease.Kind = .owner,
                       ports: [Int]) -> ServicesLease {
        ServicesLease(pid: pid, pidStartedAt: "t", kind: kind, runtime: "docker", endpoint: "e", prefix: prefix,
                      generation: "g", workspace: "w", project: project, profile: "p",
                      publishedPorts: ports.map { .init(hostIP: "127.0.0.1", hostPort: $0, proto: "tcp", service: "s") })
    }

    private let want = [ServicesPortConflict.Want(hostIP: "127.0.0.1", hostPort: 8090, proto: "tcp")]

    func testFindsOtherPrefixHolder() {
        let found = ServicesPortConflict.holder(
            wanted: want, leases: [lease(pid: 1, prefix: "mine", project: "B", ports: [8090]),
                                   lease(pid: 22872, prefix: "other", project: "sutstore_ios", ports: [8090])],
            myPrefix: "mine", isAlive: { _ in true })
        XCTAssertEqual(found?.lease.pid, 22872)
        let hint = ServicesPortConflict.hint(found!)
        XCTAssertTrue(hint.contains("port 8090"))
        XCTAssertTrue(hint.contains("pid 22872"))
        XCTAssertTrue(hint.contains("`fleetest services down --project sutstore_ios --profile p`"))
    }

    func testIgnoresDeadAndNonOverlapping() {
        let other = lease(pid: 2, prefix: "other", project: "X", ports: [8090])
        XCTAssertNil(ServicesPortConflict.holder(wanted: want, leases: [other], myPrefix: "mine", isAlive: { _ in false }))
        XCTAssertNil(ServicesPortConflict.holder(
            wanted: want, leases: [lease(pid: 3, prefix: "other", project: "X", ports: [9000])],
            myPrefix: "mine", isAlive: { _ in true }))
    }

    func testWildcardHostIPOverlaps() {
        let wild = ServicesLease.PublishedPort(hostIP: "0.0.0.0", hostPort: 8090, proto: "tcp", service: "s")
        XCTAssertTrue(ServicesPortConflict.overlaps(want[0], wild))
    }
}
