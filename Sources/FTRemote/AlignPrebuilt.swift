// AlignPrebuilt.swift
// `remote align` が、手元でビルド済みの製品をランナーへ送ってランナーの `swift build` を省くときの純粋部分。
// 判定 = `decide`(製品ごと)・鮮度 = `isFresh`・ランナー側の取り込み = `RemoteAlignPlan.buildScript`。I/O は Sources/fleetest/RemoteAlign.swift。
// **送る側の判定は「送る価値があるか」の予測で、使ってよいかの砦はランナー側**(toolchain の一致・`api macho-check`)。
// 予測を誤っても、無駄に送るか、ランナーで従来どおりビルドするだけ(誤った緑は作らない)。

import FTCore
import Foundation

public enum AlignPrebuilt {
    /// 製品ごとの判定の入力。どれか1つでも欠ければ送らずランナーでビルドする
    public struct Conditions: Equatable, Sendable {
        /// `--tool-rev` 無し(コミット由来のときは手元の製品の中身と一致する保証が無い)
        public let fromWorkingTree: Bool
        /// 手元の製品がこのクローンの `.build` の下にある(別のクローンのバイナリを送らない)
        public let builtInThisClone: Bool
        /// 手元の製品が、ソースの閉包のどのファイルよりも新しい(`isFresh`)
        public let binaryFresh: Bool
        /// この Mac の Xcode の1行(`localToolchainLine`)が読めた
        public let localToolchainReadable: Bool
        /// ランナーの Xcode の1行との完全一致。nil = 照会が無い・読めない(ランナー側の照合に任せて送る)
        public let runnerToolchainIdentical: Bool?
        /// 前回の成功したビルドから閉包が無変更で、ランナーの `ft_build` が省くと見込める(`fleetest` は常に false)
        public let unchangedSinceLastBuild: Bool

        public init(fromWorkingTree: Bool, builtInThisClone: Bool, binaryFresh: Bool, localToolchainReadable: Bool,
                    runnerToolchainIdentical: Bool?, unchangedSinceLastBuild: Bool) {
            self.fromWorkingTree = fromWorkingTree
            self.builtInThisClone = builtInThisClone
            self.binaryFresh = binaryFresh
            self.localToolchainReadable = localToolchainReadable
            self.runnerToolchainIdentical = runnerToolchainIdentical
            self.unchangedSinceLastBuild = unchangedSinceLastBuild
        }
    }

    public enum Decision: Equatable, Sendable {
        /// 送る(ランナー側の照合を通れば取り込み、通らなければそこでビルド)
        case ship
        /// 送らない: ランナーが「無変更」で省く見込み
        case notNeeded
        /// 送らずランナーでビルドする(理由はランナーのログへ出る)
        case buildOnRunner(reason: String)
    }

    public static func decide(_ c: Conditions) -> Decision {
        if c.unchangedSinceLastBuild { return .notNeeded }
        guard c.fromWorkingTree else {
            return .buildOnRunner(reason: "--tool-rev is set, so the local build may not match the revision being aligned")
        }
        guard c.builtInThisClone else {
            return .buildOnRunner(reason: "the local executable was not built in this clone's .build")
        }
        guard c.binaryFresh else {
            return .buildOnRunner(reason: "the local build is missing or older than its sources (build locally before aligning to send it)")
        }
        guard c.localToolchainReadable else {
            return .buildOnRunner(reason: "this Mac's Xcode version could not be read")
        }
        if c.runnerToolchainIdentical == false {
            return .buildOnRunner(reason: "the runner's Xcode differs from this Mac's")
        }
        return .ship
    }

    /// 送る製品・送らない製品の理由・照合に使う手元の Xcode の1行。`stagingDirectory` は送り先
    /// (アラインのヘルパーと同じ一時ディレクトリ。`fleetest` はヘルパー自身 = 二重に送らない)。
    /// `.none` は何も送らない(従来どおり全部ランナーでビルド・取り込みの文も出さない)
    public struct Plan: Equatable, Sendable {
        /// 送る製品(`fleetest` が先・以降は `RemoteAlignPlan.buildOrder` の順)
        public let shipped: [String]
        /// ランナーでビルドする製品 → 理由(`notNeeded` は載せない = ランナーが省く)
        public let reasons: [String: String]
        public let localToolchain: String
        public let stagingDirectory: String

        public init(shipped: [String], reasons: [String: String], localToolchain: String, stagingDirectory: String) {
            self.shipped = shipped
            self.reasons = reasons
            self.localToolchain = localToolchain
            self.stagingDirectory = stagingDirectory
        }

        public static let none = Plan(shipped: [], reasons: [:], localToolchain: "", stagingDirectory: "")
        public var isActive: Bool { !stagingDirectory.isEmpty }

        public func staged(in directory: String) -> Plan {
            Plan(shipped: shipped, reasons: reasons, localToolchain: localToolchain, stagingDirectory: directory)
        }
    }

    /// 製品ごとの判定から計画を作る(`decisions` は `fleetest` を含む全製品)
    public static func plan(decisions: [String: Decision], localToolchain: String) -> Plan {
        let order = ["fleetest"] + RemoteAlignPlan.buildOrder
        var shipped: [String] = [], reasons: [String: String] = [:]
        for product in order {
            switch decisions[product] {
            case .ship?: shipped.append(product)
            case .buildOnRunner(let reason)?: reasons[product] = reason
            case .notNeeded?: break
            case nil: reasons[product] = "no decision was made for it"
            }
        }
        return Plan(shipped: shipped, reasons: reasons, localToolchain: localToolchain, stagingDirectory: "")
    }

    // MARK: - 鮮度

    /// `fleetest` のソースの閉包(`Package.swift` の依存と等号で突き合わせるテストが砦。
    /// `productSourceClosure` の表は `fleetest` を持たない = 常にビルドする製品なので別に持つ)
    public static let fleetestSourceClosure = [
        "Sources/fleetest", "Sources/FTCore", "Sources/FTRemote", "Sources/FTServices", "Sources/FTBridgeClient",
        "Sources/FTFoundationModels", "Sources/FTAndroid", "Sources/FTDSL", "Sources/FTDSLMacros",
        "Sources/FTCoreSimShim", "Sources/FTEmulatorGrpc",
    ]

    /// 製品の入力(リポジトリ直下からの相対)。閉包 + `Package.swift` / `Package.resolved`
    public static func inputPaths(product: String) -> [String] {
        let closure = product == "fleetest" ? fleetestSourceClosure : (RemoteAlignPlan.productSourceClosure[product] ?? [])
        return closure + ["Package.swift", "Package.resolved"]
    }

    /// ディレクトリの更新時刻も含める(ファイルの削除はディレクトリの時刻にしか出ない)。`.DS_Store` と隠しディレクトリ(`.build` 等)は見ない。
    /// 読めないものがあれば nil(= 判定できない)
    static func newestModification(of root: URL, fileManager: FileManager = .default) -> Date? {
        guard let rootDate = (try? root.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return nil }
        if !isDirectory.boolValue { return rootDate }
        var newest = rootDate
        var failed = false
        guard let walker = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles], errorHandler: { _, _ in failed = true; return true }) else { return nil }
        for case let url as URL in walker {
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
                return nil
            }
            newest = max(newest, date)
        }
        return failed ? nil : newest
    }

    /// 手元の製品が入力のどれよりも**新しい**(厳密に >)。**迷ったら false**: 入力の欠け(`Package.resolved` 以外)・
    /// 読めない時刻・同時刻はすべて「新しくない」= ランナーでビルドする。
    /// 限界: 編集がビルドの最中に入った場合、編集の時刻はバイナリより古く見えて新しいと誤る(ビルド→揃えるの順で使う前提)
    public static func isFresh(binary: URL, repoRoot: URL, product: String, fileManager: FileManager = .default) -> Bool {
        guard let built = (try? binary.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              fileManager.isExecutableFile(atPath: binary.path) else { return false }
        for relative in inputPaths(product: product) {
            let url = repoRoot.appendingPathComponent(relative)
            guard fileManager.fileExists(atPath: url.path) else {
                if relative == "Package.resolved" { continue }
                return false
            }
            guard let newest = newestModification(of: url, fileManager: fileManager), newest < built else { return false }
        }
        return true
    }

    // MARK: - Xcode の1行

    /// `ToolchainFingerprint.current()`("Xcode 27.0 Build version 27A5228h / iphonesimulator 24A434")から、
    /// `RemoteAlignPlan.xcodeVersionOneLine` が作るのと同じ1行("Xcode 27.0 Build version 27A5228h")を取り出す。読めなければ nil
    public static func localToolchainLine(fingerprint: String?) -> String? {
        guard let fingerprint, let range = fingerprint.range(of: " / iphonesimulator ") else { return nil }
        let line = String(fingerprint[..<range.lowerBound])
        return line.isEmpty ? nil : line
    }
}
