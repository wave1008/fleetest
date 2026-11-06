import XCTest
@testable import FTBridgeClient
import FTCore

/// terminate の後に別の経路(アイコン・activate)で注入無しに起こし直されたアプリへの接続断は、「this session stopped it」と言わない
final class InAppDriverRelaunchedElsewhereTests: XCTestCase {
    /// 何も待ち受けていないポート(bind して閉じる)へ向けた、terminate 後の状態のドライバ
    private func driver(alive: Bool?) -> InAppDriver {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        _ = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let port = UInt16(bigEndian: addr.sin_port)
        close(fd)
        let d = InAppDriver(repoRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
                            udid: "00000000-0000-0000-0000-000000000000", port: port, ownBundleID: "com.example.app")
        d.appRunningProbe = { _ in alive }
        d.markStoppedForTest(bundleID: "com.example.app")
        return d
    }

    private func fate(of d: InAppDriver) async -> (AppFate?, String) {
        do { _ = try await d.status(); return (nil, "no error") }
        catch DriverError.bridgeConnectionRefused(let ctx, let detail) { return (ctx.appFate, detail) }
        catch { return (nil, "\(error)") }
    }

    func testStillStoppedWhenTheProcessIsGone() async {
        let (f, _) = await fate(of: driver(alive: false))
        XCTAssertEqual(f, .stoppedBySession)
    }

    func testNotStoppedWhenTheProcessRunsAgainAndTheMarkStaysDropped() async {
        let d = driver(alive: true)
        let (f, detail) = await fate(of: d)
        XCTAssertNil(f)
        XCTAssertTrue(detail.contains("started without the in-app bridge"), detail)
        d.appRunningProbe = { _ in false }
        let (again, _) = await fate(of: d)
        XCTAssertNil(again, "印は落としたまま")
    }

    func testUnknownLifeKeepsTheStoppedAttribution() async {
        let (f, _) = await fate(of: driver(alive: nil))
        XCTAssertEqual(f, .stoppedBySession)
    }
}
