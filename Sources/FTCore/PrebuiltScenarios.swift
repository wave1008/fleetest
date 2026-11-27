// PrebuiltScenarios.swift
// 親がビルド済みのシナリオ実行バイナリをランナーへ送り、ランナーの子がビルドを省く仕組みの純粋部分。
// 親の判定 = `decide`(RemoteRunDispatcher が呼ぶ)・子の受け入れ = `ScenarioHost.usePrebuilt`。
// 送るのは自己完結の実行ファイル1本(システムの dylib 以外に依存しない)。ランナーでの swift build は 19〜34 秒/対象。

import Foundation

public enum PrebuiltScenarios {
    /// 子へ渡す内部フラグ(`ChildPrebuiltScenariosOption`。RunCommonOptions には置かない = ヘルプに出ない)
    public static let flag = "--prebuilt-scenarios"
    public static let originRootFlag = "--prebuilt-origin-root"
    /// ディスパッチ単位ディレクトリの下の置き場(回収後の `rm -rf <stamp>` で一緒に消える)
    public static let stagingDirName = "prebuilt"

    /// 親が送るかを決める入力。**どれか1つでも満たさなければ送らない**(子は今までどおり自分でビルドする)
    public struct Conditions: Equatable, Sendable {
        /// 手元の製品が新しい(`ScenarioHost.build` が省くのと同じ条件: 指紋が一致しバイナリが実在)
        public let localBinaryFresh: Bool
        /// ツールの「全体の要約」(`revisionCompatible` の判定用の要約ではなく align が揃える単位)の一致。nil = 比べられない
        public let digestMatches: Bool?
        /// toolchain の文字列の完全一致(ベータ seed 差の advisory は不一致)。nil = 読めない
        public let toolchainIdentical: Bool?
        /// 照合の手元の値が作業ツリー由来(`--tool-rev` はコミット由来で、手元の製品の中身と一致する保証が無い)
        public let toolFromWorkingTree: Bool

        public init(localBinaryFresh: Bool, digestMatches: Bool?, toolchainIdentical: Bool?, toolFromWorkingTree: Bool) {
            self.localBinaryFresh = localBinaryFresh
            self.digestMatches = digestMatches
            self.toolchainIdentical = toolchainIdentical
            self.toolFromWorkingTree = toolFromWorkingTree
        }
    }

    public enum Decision: Equatable, Sendable {
        case send
        case skip(reason: String)
    }

    public static func decide(_ conditions: Conditions) -> Decision {
        guard conditions.localBinaryFresh else {
            return .skip(reason: "the local scenario build is missing or out of date")
        }
        guard conditions.toolFromWorkingTree else {
            return .skip(reason: "--tool-rev is set, so the local build may not match the compared tool content")
        }
        guard conditions.digestMatches == true else {
            return .skip(reason: "the runner's tool content is not identical to this Mac's"
                + " (only the run-relevant digest was required to match)")
        }
        guard conditions.toolchainIdentical == true else {
            return .skip(reason: "the runner's Xcode build differs from this Mac's (or could not be read)")
        }
        return .send
    }

    /// ランナー上の置き場(`<workDir>/.fleetest/dispatch/<stamp>/prebuilt/<製品名>`)。
    /// **ファイル名は製品名のまま**(サンドボックスの枠と TMPDIR が実行ファイル名で決まる)
    public static func stagedPath(workDir: String, stamp: String, productName: String) -> String {
        stagingDir(workDir: workDir, stamp: stamp) + "/" + productName
    }

    public static func stagingDir(workDir: String, stamp: String) -> String {
        workDir + "/.fleetest/dispatch/" + stamp + "/" + stagingDirName
    }

    /// 子の引数へ足す4語(`flag <path> originRootFlag <root>`)
    public static func args(remotePath: String, originRoot: String) -> [String] {
        [flag, remotePath, originRootFlag, originRoot]
    }

    /// シナリオ実行バイナリ内の `#filePath` から外す手元(ビルドした機械)のパッケージルートの接頭辞
    public static func stripOriginRoot(_ path: String, originRoot: String?) -> String {
        guard let originRoot, !originRoot.isEmpty else { return path }
        let prefix = originRoot.hasSuffix("/") ? originRoot : originRoot + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}
