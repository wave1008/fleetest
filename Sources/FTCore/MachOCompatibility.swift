// 送られてきた実行バイナリ(`ScenarioHost.usePrebuilt`)がこの機械で動くかを、Mach-O のヘッダだけで見る純粋な読み取り。
// 見るのは CPU の種類と最低 OS(LC_BUILD_VERSION の macOS / LC_VERSION_MIN_MACOSX)だけ。読めなければ `.unreadable` = 呼び手は使わない。
// fat(universal)は該当アーキテクチャのスライスを探す。ファイルは `read(offset, length)` 越しに必要な所だけ読む(fat のスライスは先頭から遠い)。

import Foundation

public enum MachOCompatibility {
    public struct Version: Equatable, Comparable, CustomStringConvertible, Sendable {
        public var major: Int, minor: Int, patch: Int
        public init(_ major: Int, _ minor: Int, _ patch: Int = 0) { self.major = major; self.minor = minor; self.patch = patch }
        /// Mach-O の xxxx.yy.zz(16/8/8 ビット)
        init(encoded v: UInt32) { self.init(Int(v >> 16), Int((v >> 8) & 0xff), Int(v & 0xff)) }
        public static func < (a: Version, b: Version) -> Bool {
            (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
        public var description: String { patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)" }
    }

    public enum Arch: String, Sendable { case arm64, x86_64 }

    public struct Slice: Equatable, Sendable {
        public var cpuType: UInt32
        /// macOS 向けの最低 OS(印が無い・macOS 以外なら nil = 制限なしと読む)
        public var minOS: Version?
        public var arch: Arch? {
            switch cpuType {
            case 0x0100_000C: return .arm64
            case 0x0100_0007: return .x86_64
            default: return nil
            }
        }
    }

    public enum Verdict: Equatable, Sendable {
        case compatible
        case unreadable
        case wrongArchitecture(have: [String], want: String)
        case osTooNew(required: Version, host: Version)
    }

    #if arch(arm64)
    public static let hostArch = Arch.arm64
    #else
    public static let hostArch = Arch.x86_64
    #endif

    public static var hostOS: Version {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return Version(v.majorVersion, v.minorVersion, v.patchVersion)
    }

    /// ファイルの先頭から必要な所だけ読んで判定する。`read` は読めた分(短くてもよい)・読めなければ nil
    public static func check(read: (_ offset: UInt64, _ length: Int) -> Data?,
                             hostArch: Arch = MachOCompatibility.hostArch,
                             hostOS: Version = MachOCompatibility.hostOS) -> Verdict {
        guard let slices = slices(read: read), !slices.isEmpty else { return .unreadable }
        guard let slice = slices.first(where: { $0.arch == hostArch }) else {
            return .wrongArchitecture(have: slices.map { $0.arch?.rawValue ?? String(format: "cpu-0x%x", $0.cpuType) },
                                      want: hostArch.rawValue)
        }
        if let minOS = slice.minOS, minOS > hostOS { return .osTooNew(required: minOS, host: hostOS) }
        return .compatible
    }

    public static func check(file: URL, hostArch: Arch = MachOCompatibility.hostArch,
                             hostOS: Version = MachOCompatibility.hostOS) -> Verdict {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return .unreadable }
        defer { try? handle.close() }
        return check(read: { offset, length in
            guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
            return try? handle.read(upToCount: length)
        }, hostArch: hostArch, hostOS: hostOS)
    }

    /// 上限(壊れたヘッダで巨大な読みをしない)。load command 全体は普通 数十 KB 以下
    static let maxLoadCommandBytes = 4 * 1024 * 1024
    static let maxFatArchitectures: UInt32 = 32

    static func slices(read: (UInt64, Int) -> Data?) -> [Slice]? {
        guard let head = read(0, 8), head.count == 8 else { return nil }
        let magicBE = be32(head, 0)
        switch magicBE {
        case 0xCAFE_BABE, 0xCAFE_BABF:
            let is64 = magicBE == 0xCAFE_BABF
            let count = be32(head, 4)
            guard count > 0, count <= maxFatArchitectures else { return nil }
            let entry = is64 ? 32 : 20
            guard let table = read(8, Int(count) * entry), table.count == Int(count) * entry else { return nil }
            var result: [Slice] = []
            for i in 0..<Int(count) {
                let base = i * entry
                let offset = is64 ? be64(table, base + 8) : UInt64(be32(table, base + 8))
                guard let slice = thinSlice(read: read, at: offset) else { return nil }
                result.append(slice)
            }
            return result
        default:
            guard let slice = thinSlice(read: read, at: 0) else { return nil }
            return [slice]
        }
    }

    private static func thinSlice(read: (UInt64, Int) -> Data?, at offset: UInt64) -> Slice? {
        guard let header = read(offset, 32), header.count == 32, le32(header, 0) == 0xFEED_FACF else { return nil }
        let cpuType = le32(header, 4)
        let ncmds = Int(le32(header, 16))
        let size = Int(le32(header, 20))
        guard size > 0, size <= maxLoadCommandBytes else { return nil }
        guard let commands = read(offset + 32, size), commands.count == size else { return nil }
        var minOS: Version?
        var position = 0
        for _ in 0..<ncmds {
            guard position + 8 <= size else { return nil }
            let cmd = le32(commands, position)
            let cmdSize = Int(le32(commands, position + 4))
            guard cmdSize >= 8, position + cmdSize <= size else { return nil }
            switch cmd {
            case 0x32 where cmdSize >= 16:  // LC_BUILD_VERSION: platform, minos, sdk, ntools
                if le32(commands, position + 8) == 1 { minOS = Version(encoded: le32(commands, position + 12)) }  // 1 = macOS
            case 0x24 where cmdSize >= 12:  // LC_VERSION_MIN_MACOSX: version, sdk
                minOS = Version(encoded: le32(commands, position + 8))
            default: break
            }
            position += cmdSize
        }
        return Slice(cpuType: cpuType, minOS: minOS)
    }

    private static func le32(_ d: Data, _ at: Int) -> UInt32 {
        let i = d.startIndex + at
        return UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
    }
    private static func be32(_ d: Data, _ at: Int) -> UInt32 {
        let i = d.startIndex + at
        return UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
    }
    private static func be64(_ d: Data, _ at: Int) -> UInt64 {
        UInt64(be32(d, at)) << 32 | UInt64(be32(d, at + 4))
    }
}
