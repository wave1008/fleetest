import FTRemote
import Foundation
import XCTest

/// 受け側のコマンドを手元の sh で実際に流す(送り手と同じ `gzip -1 -c` の出力を stdin に渡す)
final class PrebuiltSendTests: XCTestCase {
    /// `gzip -1 -c <src>` の出力(truncateTo があればその先頭だけ)を受け側のコマンドへ流す。パイプは sh の中だけ(読み書きの詰まりを避ける)
    private func send(_ source: URL, to command: String, truncateTo bytes: Int? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let cut = bytes.map { " | head -c \($0)" } ?? ""
        process.arguments = ["-c", "/usr/bin/gzip -1 -c \"$1\"\(cut) | { \(command); }", "sh", source.path]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PrebuiltSendTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testReceivesAnExecutableCopyUnderAStagingDirItCreates() throws {
        let staging = try scratch().appendingPathComponent("with space/prebuilt")
        let target = staging.appendingPathComponent("fleetest-scenarios-X")
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        let source = try scratch().appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.write(to: source)
        let status = try send(source, to: PrebuiltSend.receiveCommand(stagingDir: staging.path, remotePath: target.path))
        XCTAssertEqual(status, 0)
        XCTAssertEqual(try Data(contentsOf: target), payload)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path + ".part"))
    }

    func testTruncatedStreamFailsAndLeavesNoFileUnderTheRealName() throws {
        let staging = try scratch()
        let target = staging.appendingPathComponent("fleetest-scenarios-X")
        let source = try scratch().appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 乱数 = 圧縮しても 2,000 バイトに収まらない(周期的なデータだと切り詰めが効かず素通りする)
        try Data((0..<200_000).map { _ in UInt8.random(in: 0...255) }).write(to: source)
        let status = try send(source, to: PrebuiltSend.receiveCommand(stagingDir: staging.path, remotePath: target.path),
                              truncateTo: 2_000)
        XCTAssertNotEqual(status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
}
