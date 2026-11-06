import XCTest
@testable import FTBridgeClient
import FTCore

/// removeApp(uninstall)も terminate と同じく「このセッションが止めた」印を立てる(続く接続断を「クラッシュ・bridge up を確かめよ」と言わない)
final class InAppDriverUninstallMarkTests: XCTestCase {
    private func driver() -> InAppDriver {
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
        d.appRunningProbe = { _ in false }
        d.setLastBundleIDForTest("com.example.app")
        return d
    }

    private func fate(of d: InAppDriver) async -> AppFate? {
        do { _ = try await d.status(); return nil }
        catch DriverError.bridgeConnectionRefused(let ctx, _) { return ctx.appFate }
        catch { return nil }
    }

    func testUninstallingTheSessionAppMarksItStopped() async {
        let d = driver()
        d.noteUninstalled(bundleID: "com.example.app")
        let f = await fate(of: d)
        XCTAssertEqual(f, .stoppedBySession)
    }

    func testUninstallingAnotherAppLeavesTheMarkUnset() async {
        let d = driver()
        d.noteUninstalled(bundleID: "com.example.other")
        let f = await fate(of: d)
        XCTAssertNil(f)
    }
}
