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
}
