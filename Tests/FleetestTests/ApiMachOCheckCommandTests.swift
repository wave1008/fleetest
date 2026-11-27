import XCTest
import FTCore
@testable import fleetest

final class ApiMachOCheckCommandTests: XCTestCase {
    /// 狙い: 判定の各値を取り違える変異(動かないものを ok と言う)で落ちる
    func testDescribeSeparatesUsableFromUnusable() {
        XCTAssertEqual(ApiMachOCheckCommand.describe(.compatible).line, "ok")
        XCTAssertTrue(ApiMachOCheckCommand.describe(.compatible).ok)
        let unusable: [MachOCompatibility.Verdict] = [
            .unreadable, .wrongArchitecture(have: ["x86_64"], want: "arm64"),
            .osTooNew(required: .init(99, 0), host: .init(27, 0)),
        ]
        for verdict in unusable {
            let described = ApiMachOCheckCommand.describe(verdict)
            XCTAssertFalse(described.ok, "\(verdict)")
            XCTAssertNotEqual(described.line, "ok")
        }
        XCTAssertTrue(ApiMachOCheckCommand.describe(unusable[1]).line.contains("x86_64"))
        XCTAssertTrue(ApiMachOCheckCommand.describe(unusable[2]).line.contains("99.0"))
    }

    /// 実ファイルで: この Mac 自身のテスト実行ファイルは動く・テキストは読めない
    func testRealFiles() throws {
        let text = FileManager.default.temporaryDirectory.appendingPathComponent("macho-check-\(UUID().uuidString)")
        try Data("not a binary".utf8).write(to: text)
        defer { try? FileManager.default.removeItem(at: text) }
        XCTAssertFalse(ApiMachOCheckCommand.describe(MachOCompatibility.check(file: text)).ok)
        let own = try XCTUnwrap(ExecutablePath.current)
        XCTAssertTrue(ApiMachOCheckCommand.describe(MachOCompatibility.check(file: own)).ok)
    }
}
