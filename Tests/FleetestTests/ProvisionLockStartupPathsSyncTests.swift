import XCTest

/// 「空きポート選択 → 起動(pid ファイルが書かれるまで)」を ProvisionLock で直列化している
/// 起動経路の集合を固定する。ロックを取らずに freePort/startDetached を撃つ経路は、同時に走ると
/// 同じ空きポートを選んで bindFailed(48) で衝突する。
/// Sources 全体から `startDetached()` / `freePort(` の呼び出しを持つファイルを拾い、表と等号で比べる。
/// **新しい起動経路は表へ足さない限り落ちる**(足すときは ProvisionLock の内側に置く)。
final class ProvisionLockStartupPathsSyncTests: XCTestCase {

    /// ロックを取る起動経路。ファイルパスは repo root からの相対
    private static let expectedLockingSources: Set<String> = [
        "Sources/FTBridgeClient/BridgeProvisioner.swift",
        "Sources/FTBridgeClient/XCUIBridgeResolver.swift",
        "Sources/fleetest/LiveBridgeAutoStarter.swift",
        // ライブ操作が「要求されたデバイスのブリッジがどこにも無い」ときに空きポートを選ぶ経路
        // (選ぶだけで起動はしない = 予約ではないが、**同時に同じポートを選ばない**ためにロックを通す)
        "Sources/fleetest/ApiLiveCommand.swift",
    ]

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// コメントを除いたコード行で、定義(`func …`)でなく呼び出しとして `startDetached(` / `freePort(` を持つファイル
    private func startupPathsInSources() throws -> [String: String] {
        let root = repoRoot()
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil))
        var found: [String: String] = [:]
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let code = text.components(separatedBy: "\n").map { $0.components(separatedBy: "//")[0] }
            let calls = code.contains { line in
                ["startDetached(", "freePort("].contains { line.contains($0) && !line.contains("func \($0)") }
            }
            if calls { found[url.path.replacingOccurrences(of: root.path + "/", with: "")] = text }
        }
        return found
    }

    func testStartupPathSetMatchesTheTable() throws {
        let found = try startupPathsInSources()
        XCTAssertGreaterThanOrEqual(found.count, 3, "起動経路が拾えていない —— 走査の前提が崩れた")
        XCTAssertEqual(Set(found.keys), Self.expectedLockingSources,
                       "空きポート選択 / startDetached を撃つファイルの集合が表と違う。新しい経路なら ProvisionLock の内側に置いて"
                       + " expectedLockingSources へ足す(ロック無しだと同じ空きポートを選んで bindFailed(48))。"
                       + " 差分: \(Set(found.keys).symmetricDifference(Self.expectedLockingSources).sorted())")
    }

    func testEachExpectedSourceReferencesProvisionLock() throws {
        for relativePath in Self.expectedLockingSources {
            let url = repoRoot().appendingPathComponent(relativePath)
            let text = try String(contentsOf: url, encoding: .utf8)
            let code = text.components(separatedBy: "\n").map { $0.components(separatedBy: "//")[0] }
            XCTAssertTrue(code.contains { $0.contains("ProvisionLock") },
                          "\(relativePath) は起動をロックで直列化しているはず(ProvisionLock 未参照)")
        }
    }
}
