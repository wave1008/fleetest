import XCTest
@testable import FTCore

/// 書き手の read-modify-write は flock で直列化する(後勝ちで片方の変更が消えない)
final class LocalConfigOI383Tests: XCTestCase {
    func testConcurrentReadModifyWriteLosesNoUpdate() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ft-oi383-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        let count = 24
        let errors = LockedValue<[Error]>([])
        DispatchQueue.concurrentPerform(iterations: count) { index in
            do {
                try LocalConfig.withUpdateLock(url: url) {
                    var config = try LocalConfig.loadForUpdate(from: url)
                    var hosts = config.remoteHosts ?? []
                    hosts.append(RemoteHostEntry(machine: "m\(index)", host: "h\(index)"))
                    config.remoteHosts = hosts
                    try config.save(to: url)
                }
            } catch { errors.withLock { $0.append(error) } }
        }
        XCTAssertTrue(errors.withLock { $0 }.isEmpty)
        XCTAssertEqual(LocalConfig.load(from: url).remoteHosts?.count, count)
    }

    func testDisabledLockPassesThrough() throws {
        let value = try LocalConfig.withUpdateLock(enabled: false) { 7 }
        XCTAssertEqual(value, 7)
    }
}
