// `AppDriver.elementRenderer(ref:)` の既定実装は nil(「答えられない」)で、`DefaultImplementationForwardingTests` は
// 501 を投げる既定しか見ない。ラッパーが転送を書き忘れると、コンパイルは通ったまま**照会が一度も届かず**、空打ちの判断が
// 黙って公開クラス(UIKit の自前の要素を取り違える)へ戻る。ラッパー(FTBridgeClient の *Driver.swift と ActionCountingDriver)は
// 必ず自分で実装し、答えるのは BridgeClient だけ(InAppDriver / SystemUIDriver / AndroidDriver は既定の nil)

import XCTest

final class ElementRendererForwardingTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTBridgeClientTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
    }

    /// 既定の nil のままでよいドライバ(理由つき)
    private static let answersNil: [String: String] = [
        "InAppDriver.swift": "in-app ブリッジは /renderer を持たない(答えるのは XCUITest ランナーだけ)",
        "SystemUIDriver.swift": "springboard 参照専用。空打ちの判断の木のドライバではない",
    ]

    func testWrappersForwardElementRenderer() throws {
        let dir = Self.repoRoot.appendingPathComponent("Sources/FTBridgeClient")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix("Driver.swift") || $0.lastPathComponent == "BridgeClient.swift" }
        XCTAssertGreaterThan(files.count, 6, "走査対象のドライバが見つからない")
        var missing: [String] = []
        for file in files where Self.answersNil[file.lastPathComponent] == nil {
            let source = try String(contentsOf: file, encoding: .utf8)
            if !source.contains("func elementRenderer(ref: Int) async -> String?") { missing.append(file.lastPathComponent) }
        }
        let counting = try String(contentsOf: Self.repoRoot.appendingPathComponent("Sources/FTCore/ActionCountingDriver.swift"), encoding: .utf8)
        if !counting.contains("func elementRenderer(ref: Int) async -> String?") { missing.append("ActionCountingDriver.swift") }
        XCTAssertTrue(missing.isEmpty,
                      "elementRenderer(ref:) の転送が無い(既定の nil に落ちて空打ちの判断に届かない): \(missing.sorted())")
    }

    func testTheNilAnsweringTableOnlyNamesRealDrivers() {
        for name in Self.answersNil.keys {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: Self.repoRoot.appendingPathComponent("Sources/FTBridgeClient/\(name)").path), name)
        }
    }
}
