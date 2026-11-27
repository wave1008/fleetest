// 送られたバイナリの CPU・最低 OS の判定(`MachOCompatibility`)。合成した Mach-O ヘッダと、手元の実バイナリで確かめる。
// 破ると: 別アーキテクチャ・新しすぎる OS 向けのバイナリを受け入れ、シナリオが全部「Bad CPU type」で赤になる。

import XCTest
@testable import FTCore

final class MachOCompatibilityTests: XCTestCase {
    typealias V = MachOCompatibility.Version

    private static func le(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)] }
    private static func be(_ v: UInt32) -> [UInt8] { le(v).reversed() }
    private static func enc(_ v: V) -> UInt32 { UInt32(v.major) << 16 | UInt32(v.minor) << 8 | UInt32(v.patch) }

    /// 薄い Mach-O(64bit)。`legacy` = LC_VERSION_MIN_MACOSX、そうでなければ LC_BUILD_VERSION(`platform` 指定可)
    private func thin(cpu: UInt32, minOS: V?, legacy: Bool = false, platform: UInt32 = 1) -> [UInt8] {
        var cmds: [UInt8] = []
        // 前置きの無関係なコマンド(LC_UUID 相当の 24 バイト)
        cmds += Self.le(0x1B) + Self.le(24) + [UInt8](repeating: 0, count: 16)
        var n = 1
        if let minOS {
            n += 1
            if legacy {
                cmds += Self.le(0x24) + Self.le(16) + Self.le(Self.enc(minOS)) + Self.le(0)
            } else {
                cmds += Self.le(0x32) + Self.le(24) + Self.le(platform) + Self.le(Self.enc(minOS)) + Self.le(0) + Self.le(0)
            }
        }
        return Self.le(0xFEED_FACF) + Self.le(cpu) + Self.le(0) + Self.le(2) + Self.le(UInt32(n)) + Self.le(UInt32(cmds.count))
            + Self.le(0) + Self.le(0) + cmds
    }

    private func verdict(_ bytes: [UInt8], arch: MachOCompatibility.Arch = .arm64, os: V = V(26, 0)) -> MachOCompatibility.Verdict {
        let data = Data(bytes)
        return MachOCompatibility.check(read: { offset, length in
            guard offset <= UInt64(data.count) else { return nil }
            return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + length))
        }, hostArch: arch, hostOS: os)
    }

    private let arm: UInt32 = 0x0100_000C
    private let x64: UInt32 = 0x0100_0007

    func testThinMatchingArchAndOSIsCompatible() {
        XCTAssertEqual(verdict(thin(cpu: arm, minOS: V(14, 0))), .compatible)
        XCTAssertEqual(verdict(thin(cpu: arm, minOS: V(26, 0))), .compatible, "等しいのは可")
        XCTAssertEqual(verdict(thin(cpu: arm, minOS: nil)), .compatible, "印が無ければ制限なし")
        XCTAssertEqual(verdict(thin(cpu: arm, minOS: V(14, 0), legacy: true)), .compatible)
    }

    func testWrongArchitectureIsRefused() {
        XCTAssertEqual(verdict(thin(cpu: arm, minOS: V(14, 0)), arch: .x86_64),
                       .wrongArchitecture(have: ["arm64"], want: "x86_64"))
        XCTAssertEqual(verdict(thin(cpu: x64, minOS: V(14, 0)), arch: .arm64),
                       .wrongArchitecture(have: ["x86_64"], want: "arm64"))
    }

    func testTooNewMinimumOSIsRefusedForBothLoadCommands() {
        XCTAssertEqual(verdict(thin(cpu: arm, minOS: V(27, 0)), os: V(26, 7, 1)), .osTooNew(required: V(27, 0), host: V(26, 7, 1)))
        XCTAssertEqual(verdict(thin(cpu: arm, minOS: V(26, 7, 2), legacy: true), os: V(26, 7, 1)),
                       .osTooNew(required: V(26, 7, 2), host: V(26, 7, 1)))
        XCTAssertEqual(verdict(thin(cpu: arm, minOS: V(27, 0), platform: 2), os: V(26, 0)), .compatible, "macOS 以外の印は読まない")
    }

    func testUnreadableIsRefused() {
        XCTAssertEqual(verdict(Array("#!/bin/sh\n".utf8)), .unreadable)
        XCTAssertEqual(verdict([]), .unreadable)
        XCTAssertEqual(verdict(Array(thin(cpu: arm, minOS: V(14, 0)).prefix(40))), .unreadable, "load command が途切れている")
    }

    /// fat: 該当スライスだけを見る(別スライスの最低 OS では落とさない)
    func testFatPicksTheHostSlice() {
        let a = thin(cpu: arm, minOS: V(14, 0)), x = thin(cpu: x64, minOS: V(27, 0))
        func fat(_ slices: [(UInt32, [UInt8])], is64: Bool) -> [UInt8] {
            let entry = is64 ? 32 : 20
            var offset = 8 + entry * slices.count
            var table: [UInt8] = [], body: [UInt8] = []
            for (cpu, bytes) in slices {
                offset = (offset + 15) & ~15
                body += [UInt8](repeating: 0, count: offset - (8 + entry * slices.count) - body.count)
                if is64 {
                    table += Self.be(cpu) + Self.be(0) + Self.be(0) + Self.be(UInt32(offset)) + Self.be(0) + Self.be(UInt32(bytes.count)) + Self.be(4) + Self.be(0)
                } else {
                    table += Self.be(cpu) + Self.be(0) + Self.be(UInt32(offset)) + Self.be(UInt32(bytes.count)) + Self.be(4)
                }
                body += bytes
                offset += bytes.count
            }
            return Self.be(is64 ? 0xCAFE_BABF : 0xCAFE_BABE) + Self.be(UInt32(slices.count)) + table + body
        }
        for is64 in [false, true] {
            let bytes = fat([(x64, x), (arm, a)], is64: is64)
            XCTAssertEqual(verdict(bytes, arch: .arm64, os: V(26, 0)), .compatible, "is64=\(is64)")
            XCTAssertEqual(verdict(bytes, arch: .x86_64, os: V(26, 0)), .osTooNew(required: V(27, 0), host: V(26, 0)))
            XCTAssertEqual(verdict(fat([(x64, x)], is64: is64), arch: .arm64), .wrongArchitecture(have: ["x86_64"], want: "arm64"))
        }
    }

    /// 実バイナリ(ビルド済みなら)がこの機械で動くと判る = 読み取りが本物の Mach-O で成り立つ
    func testRealBuiltBinaryIsCompatibleWithThisHost() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = root.appendingPathComponent(".build/debug/fleetest")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path), "not built")
        XCTAssertEqual(MachOCompatibility.check(file: binary), .compatible)
        let other: MachOCompatibility.Arch = MachOCompatibility.hostArch == .arm64 ? .x86_64 : .arm64
        guard case .wrongArchitecture = MachOCompatibility.check(file: binary, hostArch: other) else {
            return XCTFail("a thin host binary must not match the other architecture")
        }
        XCTAssertEqual(MachOCompatibility.check(file: URL(fileURLWithPath: "/bin/sh")), .compatible, "システムの fat バイナリ")
    }
}
