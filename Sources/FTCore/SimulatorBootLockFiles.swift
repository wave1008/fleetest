// Simulator 起動の枠(`SimulatorBootSlots`。FTBridgeClient)のロックファイルの名前と枠数の唯一の定義元。
// サンドボックスが書き込みを拒否する一覧(`ScenarioSandbox.writeDeniedPaths`)と同じ値を使う = 片方だけ変えて漏れない。
// flock は inode に付くので、子が消す・置き換えると機械全体の排他が崩れる。

import Foundation

public enum SimulatorBootLockFiles {
    /// 同時に起動してよい台数 = 枠の数(ユーザー決定。根拠は `SimulatorBootSlots.concurrency`)
    public static let slotCount = 2

    public static func fileName(slot: Int) -> String { "sim-boot.lock.\(slot)" }

    /// ホーム相対の置き場(`FileManager` の cachesDirectory = `~/Library/Caches` の下)
    static let homeRelativeDirectory = "Library/Caches/fleetest"

    /// ホーム直下から見た全枠のファイル(サンドボックスの拒否用)
    static func homeRelativePaths() -> [String] {
        (0..<slotCount).map { homeRelativeDirectory + "/" + fileName(slot: $0) }
    }
}
