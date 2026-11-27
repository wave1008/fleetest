// cfprefsd に消させてよい設定のドメインの判定(SimulatorPreferencesPath)。破ると: 子が容器の中の symlink でホストの設定を
// 消させられる / 空白や記号の入った SDK のドメインで clearAppData が失敗する
import XCTest
@testable import FTCore

final class SimulatorPreferencesPathTests: XCTestCase {
    private var root: URL!
    private var container: String { root.appendingPathComponent("Data/Application/ABC-1").path }
    private var outside: URL { root.appendingPathComponent("host/Library/Preferences") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("prefpath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: container + "/Library/Preferences", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: outside.appendingPathComponent("com.apple.dock.plist").path, contents: Data())
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testDomainNames() {
        for ok in ["com.example.app", "Some SDK", "group.com.example+beta", "-g", "日本語", "cache.plist"] {
            XCTAssertTrue(SimulatorPreferencesPath.isDomainName(ok), ok)
        }
        for bad in ["", ".", "..", "a/b", "a\nb", "a\u{7f}"] {
            XCTAssertFalse(SimulatorPreferencesPath.isDomainName(bad), bad)
        }
    }

    func testDomainInsideTheRealPreferencesDirectory() throws {
        XCTAssertTrue(SimulatorPreferencesPath.isDomain(container + "/Library/Preferences/com.example.app", inContainer: container))
        try FileManager.default.createDirectory(atPath: container + "/Library/Preferences/ByHost", withIntermediateDirectories: true)
        XCTAssertTrue(SimulatorPreferencesPath.isDomain(container + "/Library/Preferences/ByHost/com.example.app.ABCD", inContainer: container))
        XCTAssertFalse(SimulatorPreferencesPath.isDomain(container + "/Library/Caches/com.example.app", inContainer: container))
        XCTAssertFalse(SimulatorPreferencesPath.isDomain(container + "/Library/Preferences/sub/x", inContainer: container))
    }

    /// `Library` を symlink にしてホストの `~/Library` へ向けた形(子は容器の中に書ける)
    func testSymlinkedLibraryIsRefused() throws {
        try FileManager.default.removeItem(atPath: container + "/Library")
        try FileManager.default.createSymbolicLink(atPath: container + "/Library", withDestinationPath: outside.deletingLastPathComponent().path)
        XCTAssertFalse(SimulatorPreferencesPath.isDomain(container + "/Library/Preferences/com.apple.dock", inContainer: container))
    }

    func testSymlinkedPreferencesDirectoryIsRefused() throws {
        try FileManager.default.removeItem(atPath: container + "/Library/Preferences")
        try FileManager.default.createSymbolicLink(atPath: container + "/Library/Preferences", withDestinationPath: outside.path)
        XCTAssertFalse(SimulatorPreferencesPath.isDomain(container + "/Library/Preferences/com.apple.dock", inContainer: container))
    }

    /// 名前に拡張子を付けた形(`defaults delete` は `x.plist` そのものに作用する)・パスそのものが symlink の形
    func testPlistNamedDomainAndSymlinkedPathAreRefused() throws {
        try FileManager.default.createSymbolicLink(atPath: container + "/Library/Preferences/x.plist",
                                                   withDestinationPath: outside.appendingPathComponent("com.apple.dock.plist").path)
        XCTAssertFalse(SimulatorPreferencesPath.isDomain(container + "/Library/Preferences/x.plist", inContainer: container))
        try FileManager.default.createSymbolicLink(atPath: container + "/Library/Preferences/y",
                                                   withDestinationPath: outside.path)
        XCTAssertFalse(SimulatorPreferencesPath.isDomain(container + "/Library/Preferences/y", inContainer: container))
    }

    func testSymlinkedPlistIsRefused() throws {
        try FileManager.default.createSymbolicLink(atPath: container + "/Library/Preferences/com.apple.dock.plist",
                                                   withDestinationPath: outside.appendingPathComponent("com.apple.dock.plist").path)
        XCTAssertFalse(SimulatorPreferencesPath.isDomain(container + "/Library/Preferences/com.apple.dock", inContainer: container))
    }
}
