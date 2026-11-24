// 別のデバイスへ移ったポートを断るとき、記憶を捨てない(mcp.md の規律)ことと、
// 起動し直したポートへ記憶を付け替えること(BridgeRecovery)を固定する。
// 捨てると、宛先を省いた次の呼び出しが keyChangedDevice の previous=nil を通って黙って新しいデバイスに固定される。

import XCTest
import FTCore
@testable import fleetest_mcp

/// `/status` にだけ答える最小 HTTP スタブ(udid を注入できる)
private final class UDIDStatusStub {
    private var serverFD: Int32 = -1
    let port: UInt16

    init(udid: String) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); throw Failure.socket }
        var assigned = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        port = UInt16(bigEndian: assigned.sin_port)
        serverFD = fd
        let status = StatusResponse(ready: true, device: "iPhone", osVersion: "-", sessionBundleID: nil,
                                    bridge: "xcuitest", udid: udid)
        let body = (try? String(data: JSONEncoder().encode(status), encoding: .utf8)) ?? "{}"
        Thread.detachNewThread { [fd] in
            while true {
                var ca = sockaddr()
                var cl = socklen_t(MemoryLayout<sockaddr>.size)
                let c = accept(fd, &ca, &cl)
                if c < 0 { break }
                var buffer = [UInt8](repeating: 0, count: 4096)
                _ = read(c, &buffer, buffer.count)
                let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                _ = response.withCString { write(c, $0, strlen($0)) }
                close(c)
            }
        }
    }

    func stop() { if serverFD >= 0 { close(serverFD); serverFD = -1 } }
    deinit { stop() }
    enum Failure: Error { case socket }
}

final class MovedDeviceKeepsMemoryTests: XCTestCase {

    /// 断った後も記憶が残り、宛先を省いた次の呼び出しも断られ続ける(黙って新しいデバイスに固定されない)
    func testRefusalKeepsTheMemoryAndKeepsRefusingCallsThatOmitTheTarget() async throws {
        let stub = try UDIDStatusStub(udid: "BBB")
        defer { stub.stop() }
        let key = "direct:ios:\(stub.port):"
        let server = MCPServer()
        server.connectedPorts[key] = stub.port
        server.udids[key] = "AAA"
        server.bridges[key] = "xcuitest"
        server.launchedBundleIDs[key] = "com.example.old"

        let first = await server.deviceIdentityChanged(key, args: ["ref": 1])
        XCTAssertNotNil(first, "別のデバイスなので断るはず")
        XCTAssertEqual(server.udids[key], "AAA", "断るときに記憶(udid)を捨てた")
        XCTAssertEqual(server.connectedPorts[key], stub.port, "断るときに記憶(port)を捨てた")
        XCTAssertEqual(server.launchedBundleIDs[key], "com.example.old", "断るときに起動アプリの記憶を捨てた")

        let second = await server.deviceIdentityChanged(key, args: ["ref": 2])
        XCTAssertEqual(second, first, "宛先を省いた次の呼び出しが断られなくなった(黙って固定される)")
        XCTAssertFalse(first?.contains("has been dropped") ?? true, first ?? "")
    }

    /// 抜け道は呼び手が台を名指すとき(udid・profile)だけ。port だけ・省略は抜けない
    func testOnlyNamingTheDeviceEscapesTheRefusal() {
        XCTAssertFalse(MCPServer.callerNamesDevice(["ref": 1]))
        XCTAssertFalse(MCPServer.callerNamesDevice(["port": 8123, "ref": 1]))
        XCTAssertTrue(MCPServer.callerNamesDevice(["udid": "BBB"]))
        XCTAssertTrue(MCPServer.callerNamesDevice(["profile": "p"]))
    }

    /// 断り文は記憶を捨てたと言わず、udid の明示で進める旨を言う
    func testRefusalTextSaysTheStateIsKeptAndHowToProceed() {
        let message = MCPServer.movedDeviceRefusal(port: 8123, previousUDID: "AAA", nowUDID: "BBB")
        XCTAssertFalse(message.contains("dropped"), message)
        XCTAssertTrue(message.contains("udid"), message)
        XCTAssertTrue(message.contains("ft_snapshot"), message)
    }

    // MARK: - BridgeRecovery: 起動し直したポートへ撃ち直す

    /// 別のポートに上がったら、撃ち直しの args はそのポートを指し、古い鍵の記憶は捨てる
    func testRecoveredOnAnotherPortRetargetsTheRetryAndMovesTheMemory() {
        let server = MCPServer()
        let key = "direct:ios:8123:"
        server.connectedPorts[key] = 8123
        server.udids[key] = "AAA"
        server.lastExplicitIOSTarget = (port: 8123, udid: "AAA")
        server.seenExplicitIOSPorts = [8123]
        server.seenExplicitIOSUDIDs[8123] = "AAA"

        let retry = server.adoptRecoveredPort(key: key, args: ["port": 8123, "ref": 1], oldPort: 8123, newPort: 8130)

        XCTAssertEqual(retry["port"] as? Int, 8130, "撃ち直し先が起動し直したポートになっていない")
        XCTAssertNil(server.connectedPorts[key], "古い鍵の記憶が残った")
        XCTAssertEqual(server.lastExplicitIOSTarget?.port, 8130)
        XCTAssertEqual(server.seenExplicitIOSPorts, [8130])
        XCTAssertEqual(server.seenExplicitIOSUDIDs[8130], "AAA")
    }

    /// 同じポートなら何も変えない
    func testRecoveredOnTheSamePortChangesNothing() {
        let server = MCPServer()
        let key = "direct:ios:8123:"
        server.connectedPorts[key] = 8123
        let retry = server.adoptRecoveredPort(key: key, args: ["port": 8123], oldPort: 8123, newPort: 8123)
        XCTAssertEqual(retry["port"] as? Int, 8123)
        XCTAssertEqual(server.connectedPorts[key], 8123)
    }

    /// profile の鍵は port を含まない: 記憶のポートだけ付け替え、ドライバは捨てて生成し直させる
    func testRecoveredOnAnotherPortForProfileKeyRebindsThePort() {
        let server = MCPServer()
        let key = MCPServer.sessionKey(["profile": "p", "project": "x"])
        server.connectedPorts[key] = 8123
        let retry = server.adoptRecoveredPort(key: key, args: ["profile": "p", "project": "x"],
                                              oldPort: 8123, newPort: 8130)
        XCTAssertEqual(server.connectedPorts[key], 8130)
        XCTAssertNil(retry["port"])
    }
}
