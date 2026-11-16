// settle: false(SettleOverride.skip)の間は、adb のキー操作の後の整定(settleViaBridge = ブリッジの POST /settle、
// 失敗時は 800ms の固定待ち)を撃たない。back() はキー操作 → settleViaBridge の順で、固定待ちに入るのは
// ブリッジを起こしに行って(= adb を呼んで)失敗した後だけ。だから「キー操作の後に adb が呼ばれたか」で見分ける
// (所要の上限で見ない: 並列の負荷で 0.5 秒を超えて落ちた。下限を見る陽性対照は負荷で崩れない)

import FTCore
import XCTest
@testable import FTAndroid

final class AndroidDriverSettleOverrideTests: XCTestCase {
    private var dir: URL!
    private var serial: String!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ft-settle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        serial = "fake-\(UUID().uuidString.prefix(8))"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-android-\(serial!).json"))
    }

    /// キー操作だけ成功し、それ以外(ブリッジの起動・転送)は失敗する adb。呼び出しを1行ずつ記録する
    private func fakeADB() throws -> (path: String, log: URL) {
        let log = dir.appendingPathComponent("calls.log")
        let url = dir.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        echo "$*" >> '\(log.path)'
        case "$*" in *keyevent*) exit 0;; *) exit 1;; esac
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return (url.path, log)
    }

    private func calls(_ log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func testBackWithSettleFalseDoesNotSettleViaTheBridge() async throws {
        let adb = try fakeADB()
        let driver = AndroidDriver(serial: serial, adbPath: adb.path)
        try await SettleOverride.$skip.withValue(true) { try await driver.back() }
        let made = calls(adb.log)
        // キー操作の1回だけ = ブリッジを起こしに行っていない = その失敗の後の 800ms の固定待ちにも入っていない
        XCTAssertEqual(made.count, 1, "キー操作の後にブリッジを起こしに行った(失敗すれば 800ms の固定待ちへ落ちる): \(made)")
        XCTAssertTrue(made.first?.contains("keyevent") == true, "\(made)")
    }

    /// キーの操作(ここでは back)の後の次の1枚はキャッシュを迂回する(Compose の画面は a11y のキャッシュが前の画面の木を返す)。
    /// 整定を飛ばした回も同じ(印は整定と独立)
    func testBackMakesTheNextSnapshotBypassTheCache() async throws {
        let adb = try fakeADB()
        let driver = AndroidDriver(serial: serial, adbPath: adb.path)
        XCTAssertFalse(driver.nextSnapshotBypassesCache)
        try await SettleOverride.$skip.withValue(true) { try await driver.back() }
        XCTAssertTrue(driver.nextSnapshotBypassesCache, "back の後の読みが a11y のキャッシュ(前の画面の木)を引く")
    }

    /// 陽性対照: 既定(settle する)ではキー操作の後にブリッジへ整定を頼みに行き、失敗すると固定待ちへ落ちる
    func testBackByDefaultSettlesViaTheBridge() async throws {
        let adb = try fakeADB()
        let driver = AndroidDriver(serial: serial, adbPath: adb.path)
        let start = Date()
        try await driver.back()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(calls(adb.log).count, 1, "キー操作の後にブリッジへ整定を頼んでいない")
        XCTAssertGreaterThanOrEqual(elapsed, 0.8, "整定の失敗時の固定待ち(800ms)を払っていない")
    }
}
