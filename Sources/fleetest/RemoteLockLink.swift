// RemoteLockLink.swift
// run 全体のロック(RR-8.5)を ssh 越しのリモートの機械へ届ける、中継役(`RemoteRunDispatcher`)の側の部品。
// 発行元は機械ごとの待ち受けを持ち(`RunLockServer.remoteSocketPaths`)、中継役は今の ssh に unix ソケットの転送
// (`-R <向こうのパス>:<その機械の待ち受け>`)を足し、向こうのパスをリモートの run へ `--lock-socket` として渡す。
// 向こうの run は手元の子と同じに、そのパスへつなぐ(出どころは「どの待ち受けで受けたか」だけで決まる)。

import FTCore
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

/// 中継役の ssh の期限(`RemoteTimeout`)を、**ロックの待ちの時間だけ**延ばす判断の持ち主(RR-8.5)。
/// 待ちの時間は発行元のロックのサーバーが数える(出どころ = このディスパッチの待ち受けごとの待ちの和集合。stdout の行は欠けうるので使わない)。
/// 期限に達するたびに `additionalMs()` を呼び、**これまでに延ばした分との差**だけ延ばす。接続が無い・切れたら延ばさない
final class RemoteLockWaitExtender: @unchecked Sendable {
    // 不変条件: control / gone / extendedMs は lock の内側(期限の待ちを持つスレッドが呼ぶ)
    private let lock = NSLock()
    private let listener: String
    private let capMs: Int
    private let connect: () -> RunLockRelayControl?
    private var control: RunLockRelayControl?
    private var gone = false
    private var extendedMs = 0

    /// - capMs: 延長の合計の上限(元の期限。`RemoteTimeoutExtension.additionalMs` の根拠)
    init(listener: String, capMs: Int, connect: @escaping () -> RunLockRelayControl?) {
        self.listener = listener
        self.capMs = capMs
        self.connect = connect
    }

    /// 今回さらに延ばすミリ秒(0 = 延ばさない)
    func additionalMs() -> Int {
        lock.withLock {
            if gone { return 0 }
            if control == nil { control = connect() }
            guard let control, let waited = control.waitedMs(listener: listener) else {
                gone = true
                return 0
            }
            let extra = RemoteTimeoutExtension.additionalMs(waitedMs: waited, extendedMs: extendedMs, capMs: capMs)
            extendedMs += extra
            return extra
        }
    }
}

/// 中継役の ssh の期限待ち(`waitExit`)と、ロックの待ちによる延長の繰り返し(RR-8.5)。時計・待ち・延長の問い合わせを注入できる形にして単体で試す。
/// - 新しい期限の起点は `max(いまの期限, いま)`: 既に過ぎた期限へ小さな増分を足すと、延長が尽きるたびにすぐ次の期限に達して
///   サーバーへの問い合わせとログが数ミリ秒ごとに続く
/// - 1回の延長は少なくとも `minimumStepSeconds`(問い合わせの頻度の下限)
/// - ログは最初の延長と最後の要約だけ
enum RemoteDeadlineWait {
    /// 1回の延長の最小の長さ(秒)。根拠: 問い合わせは制御用の接続の往復(ローカルのソケットで数ミリ秒)だが、待ちが続く間は
    /// 延長のたびに起きるので、頻度を「5秒に1回以下」に抑える。延長の合計は延長側(`RemoteLockWaitExtender`)が元の期限までに数えるので、
    /// 最小の長さによる超過は1回あたり 5 秒以内
    static let minimumStepSeconds = 5

    struct Result: Equatable {
        var timedOut: Bool
        /// 実際に期限へ足した合計(ミリ秒。最小の長さによる超過を含む)
        var extendedMs: Int
    }

    static func run(initialDeadline: DispatchTime,
                    waitExit: (DispatchTime) -> DispatchTimeoutResult,
                    capMs: Int,
                    extension additionalMs: (() -> Int)?,
                    now: () -> DispatchTime = { .now() },
                    log: (String) -> Void) -> Result {
        var deadline = initialDeadline
        var timedOut = waitExit(deadline) == .timedOut
        var extendedMs = 0
        var cycles = 0
        while timedOut, let additionalMs {
            let extra = additionalMs()
            guard extra > 0 else { break }
            // 延長の合計は上限(元の期限)まで: 最小の長さによる超過で、待ちが細く続く run が上限を超えて延び続けない
            let step = min(max(extra, minimumStepSeconds * 1000), capMs - extendedMs)
            guard step > 0 else { break }
            let base = max(deadline.uptimeNanoseconds, now().uptimeNanoseconds)
            deadline = DispatchTime(uptimeNanoseconds: base + UInt64(step) * 1_000_000)
            extendedMs += step
            cycles += 1
            if cycles == 1 {
                log("==> the remote run waited on run-wide locks; extending its time limit (reported once; a summary follows)")
            }
            timedOut = waitExit(deadline) == .timedOut
        }
        if cycles > 0 {
            log("==> the time limit of the remote run was extended by \(extendedMs / 1000)s for run-wide lock waits"
                + " (\(cycles) extension(s))")
        }
        return Result(timedOut: timedOut, extendedMs: extendedMs)
    }
}
