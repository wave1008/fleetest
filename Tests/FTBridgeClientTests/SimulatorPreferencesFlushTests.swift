// clearAppData が cfprefsd に消させる設定のドメインの集め方(外観が届かない件 = docs/verification/resolved.md)。破ると: 設定でないファイルまでドメインと読む /
// 置き場の無い容器で無いドメインを撃って 1(not found)で失敗する
import XCTest
@testable import FTBridgeClient

final class SimulatorPreferencesFlushTests: XCTestCase {
    private var container: URL!

    override func setUpWithError() throws {
        container = FileManager.default.temporaryDirectory.appendingPathComponent("prefs-\(UUID().uuidString)")
        let prefs = container.appendingPathComponent("Library/Preferences")
        try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
        for name in ["com.example.app.plist", "com.vendor.sdk.plist", "notes.txt"] {
            FileManager.default.createFile(atPath: prefs.appendingPathComponent(name).path, contents: Data())
        }
    }

    override func tearDown() { try? FileManager.default.removeItem(at: container) }

    /// ディスクにある .plist だけがドメイン(設定でないファイルは含めない)
    func testListsOnlyPlistDomains() {
        let dir = container.path + "/Library/Preferences/"
        XCTAssertEqual(SimulatorPreferencesFlush.domainPaths(container: container.path),
                       [dir + "com.example.app", dir + "com.vendor.sdk"])
    }

    /// 設定の置き場が無い容器(group の容器・作られたばかりのアプリ)は空 = 何も撃たない(無いドメインの delete は 1 で終わる)
    func testMissingPreferencesDirectoryYieldsNothing() throws {
        try FileManager.default.removeItem(at: container.appendingPathComponent("Library"))
        XCTAssertEqual(SimulatorPreferencesFlush.domainPaths(container: container.path), [])
    }

    /// 置き場が容器の外を指していれば nil(呼び手が断る)・symlink の plist は外す
    func testSymlinkedPreferencesIsRefusedAndSymlinkedPlistIsSkipped() throws {
        let outside = container.appendingPathComponent("../outside-\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let prefs = container.appendingPathComponent("Library/Preferences")
        try FileManager.default.createSymbolicLink(at: prefs.appendingPathComponent("com.linked.plist"),
                                                   withDestinationURL: outside.appendingPathComponent("x.plist"))
        XCTAssertEqual(SimulatorPreferencesFlush.domainPaths(container: container.path),
                       [prefs.path + "/com.example.app", prefs.path + "/com.vendor.sdk"])
        try FileManager.default.removeItem(at: prefs)
        try FileManager.default.createSymbolicLink(at: prefs, withDestinationURL: outside)
        XCTAssertNil(SimulatorPreferencesFlush.domainPaths(container: container.path))
    }

    /// キーが無い plist(空の dict・0 バイト・無い)は、cfprefsd が not found で 1 を返しても失敗にしない。読めない形は「ある」
    func testHasKeys() throws {
        let dir = container.appendingPathComponent("Library/Preferences")
        func write(_ name: String, _ object: Any?) throws -> String {
            let path = dir.appendingPathComponent(name).path
            let data = try object.map { try PropertyListSerialization.data(fromPropertyList: $0, format: .xml, options: 0) } ?? Data()
            FileManager.default.createFile(atPath: path, contents: data)
            return path
        }
        XCTAssertFalse(SimulatorPreferencesFlush.hasKeys(plist: try write("empty.plist", [String: Any]())))
        XCTAssertFalse(SimulatorPreferencesFlush.hasKeys(plist: try write("zero.plist", nil)))
        XCTAssertFalse(SimulatorPreferencesFlush.hasKeys(plist: dir.appendingPathComponent("missing.plist").path))
        XCTAssertTrue(SimulatorPreferencesFlush.hasKeys(plist: try write("keys.plist", ["launch_count": 2])))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("garbage.plist").path, contents: Data("not a plist".utf8))
        XCTAssertTrue(SimulatorPreferencesFlush.hasKeys(plist: dir.appendingPathComponent("garbage.plist").path))
    }
}
