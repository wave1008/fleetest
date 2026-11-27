// clearAppData が cfprefsd に消させる設定のドメインの集め方(外観が届かない件 = docs/verification/resolved.md)。破ると:
// 設定でないファイルまでドメインと読む / ByHost のドメインを残す / symlink の先の設定を消させる・黙って外してキャッシュを残す /
// 置き場の無い容器で無いドメインを撃って 1(not found)で失敗する / 値の無い plist で clearAppData が止まる
import XCTest
@testable import FTBridgeClient

final class SimulatorPreferencesFlushTests: XCTestCase {
    private var container: URL!
    private var prefs: URL { container.appendingPathComponent("Library/Preferences") }

    override func setUpWithError() throws {
        container = FileManager.default.temporaryDirectory.appendingPathComponent("prefs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: prefs.appendingPathComponent("ByHost"), withIntermediateDirectories: true)
        for name in ["com.example.app.plist", "com.vendor.sdk.plist", "notes.txt", "ByHost/com.example.app.ABCD.plist"] {
            FileManager.default.createFile(atPath: prefs.appendingPathComponent(name).path, contents: Data())
        }
    }

    override func tearDown() { try? FileManager.default.removeItem(at: container) }

    /// ディスクにある .plist だけがドメイン(設定でないファイルは含めない)。ByHost の分も含める
    func testListsPlistDomainsIncludingByHost() {
        let dir = prefs.path + "/"
        XCTAssertEqual(SimulatorPreferencesFlush.domainPaths(container: container.path),
                       .domains([dir + "ByHost/com.example.app.ABCD", dir + "com.example.app", dir + "com.vendor.sdk"]))
    }

    /// 設定の置き場が無い容器(group の容器・作られたばかりのアプリ)は空 = 何も撃たない(無いドメインの delete は 1 で終わる)
    func testMissingPreferencesDirectoryYieldsNothing() throws {
        try FileManager.default.removeItem(at: container.appendingPathComponent("Library"))
        XCTAssertEqual(SimulatorPreferencesFlush.domainPaths(container: container.path), .domains([]))
    }

    /// 置き場か plist が symlink なら断る(黙って外すと、そのドメインのキャッシュを残したまま「消えた」と言う)
    func testSymlinksAreRefusedNotSkipped() throws {
        let outside = container.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: prefs.appendingPathComponent("com.linked.plist"),
                                                   withDestinationURL: outside.appendingPathComponent("x.plist"))
        guard case .refused = SimulatorPreferencesFlush.domainPaths(container: container.path) else {
            return XCTFail("symlink の plist を断っていない")
        }
        try FileManager.default.removeItem(at: prefs)
        try FileManager.default.createSymbolicLink(at: prefs, withDestinationURL: outside)
        guard case .refused = SimulatorPreferencesFlush.domainPaths(container: container.path) else {
            return XCTFail("symlink の置き場を断っていない")
        }
    }

    /// 置き場が普通のファイル(読めない)なら、symlink ではなく「読めない」と言って断る
    func testUnreadablePreferencesLocationIsRefusedWithItsOwnReason() throws {
        try FileManager.default.removeItem(at: prefs)
        FileManager.default.createFile(atPath: prefs.path, contents: Data())
        guard case .refused(let why) = SimulatorPreferencesFlush.domainPaths(container: container.path) else {
            return XCTFail("読めない置き場を断っていない")
        }
        XCTAssertTrue(why.contains("not a readable directory"), why)
    }

    /// 値が無い plist(空の dict・0 バイト・無い・読めない形)は、cfprefsd が not found で 1 を返しても失敗にしない
    func testHasValues() throws {
        func write(_ name: String, _ object: Any?) throws -> String {
            let path = prefs.appendingPathComponent(name).path
            let data = try object.map { try PropertyListSerialization.data(fromPropertyList: $0, format: .xml, options: 0) } ?? Data()
            FileManager.default.createFile(atPath: path, contents: data)
            return path
        }
        XCTAssertFalse(SimulatorPreferencesFlush.hasValues(plist: try write("empty.plist", [String: Any]())))
        XCTAssertFalse(SimulatorPreferencesFlush.hasValues(plist: try write("zero.plist", nil)))
        XCTAssertFalse(SimulatorPreferencesFlush.hasValues(plist: prefs.appendingPathComponent("missing.plist").path))
        XCTAssertFalse(SimulatorPreferencesFlush.hasValues(plist: try write("array.plist", [1, 2])))
        FileManager.default.createFile(atPath: prefs.appendingPathComponent("garbage.plist").path, contents: Data("not a plist".utf8))
        XCTAssertFalse(SimulatorPreferencesFlush.hasValues(plist: prefs.appendingPathComponent("garbage.plist").path))
        XCTAssertTrue(SimulatorPreferencesFlush.hasValues(plist: try write("keys.plist", ["launch_count": 2])))
    }
}
