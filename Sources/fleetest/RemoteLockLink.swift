// RemoteLockLink.swift
// run 全体のロック(RR-8.5)を ssh 越しのリモートの機械へ届ける、中継役(`RemoteRunDispatcher`)の側の部品。
// 発行元は機械ごとの待ち受けを持ち(`RunLockServer.remoteSocketPaths`)、中継役は今の ssh に unix ソケットの転送
// (`-R <向こうのパス>:<その機械の待ち受け>`)を足し、向こうのパスをリモートの run へ `--lock-socket` として渡す。
// 向こうの run は手元の子と同じに、そのパスへつなぐ(出どころは「どの待ち受けで受けたか」だけで決まる)。

import FTRemote
import Foundation

struct RemoteLockLink: Equatable {
    /// 発行元のその機械の待ち受け(転送先)
    let machineSocket: String
    /// 発行元の手元の待ち受け(ssh の終わり・向こうの run の終わりの知らせ用)
    let controlSocket: String
    /// 向こうの機械の転送元のパス
    let remotePath: String

    /// 向こうのパス: `/tmp/ftlock-<8桁の16進>.sock`。根拠: ①向こうの `$TMPDIR` を知らずに決められる(ssh の非対話の環境では
    /// 対話シェルと違う場合がある。`/tmp` はどちらの OS にもある)・②sun_path の上限(104 バイト)に収まる短さ(25 バイト)・
    /// ③ディスパッチごとに一意(同じ機械へ同時に別の run が走っても、前の run の古いファイルが残っていても衝突しない)・
    /// ④`:` を含まない(`-R` の書式は `:` で転送元と転送先を分けるので、含むと曖昧になる)
    static func randomRemotePath() -> String {
        "/tmp/ftlock-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased() + ".sock"
    }

    /// 両方の待ち受けが渡されたときだけ作る。手元のパスが `:` を含むと `-R` で表せないので作らない(nil = 転送しない =
    /// リモートの run は呼んだら失敗する)
    static func make(machineSocket: String?, controlSocket: String?, remotePath: String = randomRemotePath()) -> RemoteLockLink? {
        guard let machineSocket, let controlSocket, !machineSocket.contains(":"), !remotePath.contains(":") else { return nil }
        return RemoteLockLink(machineSocket: machineSocket, controlSocket: controlSocket, remotePath: remotePath)
    }

    /// 今の run の ssh へ足す引数。**`ExitOnForwardFailure=no` を明示する**(転送が張れなくても run 全体を落とさない。利用者の ssh_config の
    /// `ExitOnForwardFailure yes` に負けない。張れなければリモートのシナリオはつなげず、ロックを呼んだ時点で英語の理由つきで失敗する)。
    /// 向こうの古いソケットのファイルは向こうの sshd の設定で決まるので、パスをディスパッチごとに一意にして衝突させない
    var sshArgs: [String] {
        SSHOptions.exitOnForwardFailureNoArgs + ["-R", "\(remotePath):\(machineSocket)"]
    }
}
