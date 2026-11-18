// ProvisionLock.swift
// ブリッジの供給の排他(.fleetest/provision.lock)。本体は BridgeProvisioner.swift

import Foundation
import Synchronization
import FTCore

/// provision() のプランニング〜起動を跨いだクロスプロセス排他(.fleetest/provision.lock への flock 助言ロック)。
/// ポート予約は pid ファイル存在で判定するが pid ファイルは起動フェーズまで書かれないため、複数の
/// fleetest プロセスが同時に provision すると同じ空きポートを選び bindFailed(48) を起こす。provision()
/// 全体をこのロックで直列化して防ぐ(pid 予約ロジックには手を入れない)。flock はプロセス終了で
/// 自動解放されるためデッドロックしない。1 プロセス内の複数デバイス並列起動は provision 内部で維持される。
public final class ProvisionLock: Sendable {
    enum LockError: Error { case openFailed(Int32) }
    private let fd: Int32
    private let released = Mutex(false)

    /// stateDir/<lockName> を flock 対象にする。既定は provision.lock(ブリッジ供給用)。
    /// 別用途(例: 実行プロファイルへのデバイス追記)は別 lockName を渡して独立させる。
    public init(stateDir: URL, lockName: String = "provision.lock") throws {
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let path = stateDir.appendingPathComponent(lockName).path
        fd = open(path, O_CREAT | O_NOFOLLOW | O_RDWR, 0o644)
        guard fd >= 0 else { throw LockError.openFailed(errno) }
    }

    /// LOCK_EX を取得。取得待ちのブロッキングは別スレッドで行い、async executor を塞がない。
    /// `onWait`: すぐ取れなかった(別のプロセスが持っている)ときだけ、待ち始める前に `waitNotice` を、その後は
    /// `stillWaitingIntervalSeconds` ごとに経過の1行を渡す。待ちは数分に及ぶことがあり(別の run が8台の供給の間持つ)、
    /// 黙って待つと止まったように見えた(`bridge up` が約 4 分半無言)。**見込みは言わない**(相手の供給の長さはこのプロセスに
    /// 分からない = DR-191)
    public func acquire(onWait: (@Sendable (String) -> Void)? = nil) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let fd = self.fd
            DispatchQueue.global().async {
                if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                    var timer: DispatchSourceTimer?
                    if let onWait {
                        onWait(Self.waitNotice)
                        let interval = Self.stillWaitingIntervalSeconds
                        let waited = LockedValue(0)
                        let source = DispatchSource.makeTimerSource(queue: .global())
                        source.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
                        source.setEventHandler {
                            onWait(Self.stillWaitingNotice(seconds: waited.withLock { $0 += interval; return $0 }))
                        }
                        source.resume()
                        timer = source
                    }
                    _ = flock(fd, LOCK_EX)
                    timer?.cancel()
                }
                cont.resume()
            }
        }
    }

    /// 経過の1行の間隔[秒]。実測の待ち(150〜180 秒)で 5〜6 行 = 止まっていないと分かり、流れを埋めない程度
    public static let stillWaitingIntervalSeconds = 30

    static func stillWaitingNotice(seconds: Int) -> String {
        "still waiting for .fleetest/provision.lock (\(seconds)s so far) — another fleetest process on this Mac is starting bridges"
    }

    /// `onWait` に渡す共通の文(供給の2経路が同じ文を出す)
    public static let waitNotice = "waiting for another fleetest process on this Mac that is starting bridges"
        + " (.fleetest/provision.lock) — it continues as soon as that process has taken its ports"

    /// **冪等**。早期解放(ポート確保が済んだ時点)と関数末尾の defer の両方から呼ばれるので、
    /// 2 回目を素通しにしないと close(fd) が無関係な fd を閉じる(fd は再利用される)
    public func release() {
        let already = released.withLock { already in
            defer { already = true }
            return already
        }
        guard !already else { return }
        _ = flock(fd, LOCK_UN)
        close(fd)
    }
}
