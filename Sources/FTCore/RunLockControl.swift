// RunLockControl.swift
// 中継役(マシンをまたぐ run の発行元が手元で起こす `run --runner <機>` のプロセス = ssh の親)が、**発行元の手元の待ち受け**へつないで、
// その機械への ssh の終わり(`sshEnded`)と向こうの run の終わり(`remoteRunEnded`)を知らせる口(RR-8.5 の持ち主不明のキー)。
// 確かめ直しの判断は `RunLockRecheck`(純粋に近い・注入で試せる)。

import Foundation

public protocol RunLockRelayControl {
    /// ssh が終わった。サーバーはそのディスパッチ(`listener` = 向こうの待ち受けのパス)の残りの持ち分を持ち主不明にして、
    /// 不明のキーの数と待ちの上限(秒)を返す。nil = 届かなかった
    func sshEnded(listener: String) -> (count: Int, capSeconds: Int)?
    /// 向こうの run が終わったと確かめた(そのディスパッチの)。送れたか
    func remoteRunEnded(listener: String) -> Bool
    /// 発行元が接続を閉じたか(閉じた = 発行元の仕事は全部終わった)
    func issuerClosed() -> Bool
}

public final class RunLockControl: RunLockRelayControl, @unchecked Sendable {
    private let descriptor: Int32
    private let channel: RunLockLineChannel
    private let lock = NSLock()

    private init(descriptor: Int32) {
        self.descriptor = descriptor
        self.channel = RunLockLineChannel(descriptor: descriptor)
    }

    deinit { close(descriptor) }

    /// つなげなければ投げる(確かめ直しをしない = 持ち主不明は run の終わりまで残る。待っている側は上限で失敗する)
    public static func connect(path: String) throws -> RunLockControl {
        let control = RunLockControl(descriptor: try UnixSocket.connect(path: path, closeOnExec: true))
        guard control.send(.hello(scenario: "run-lock-relay", machine: "relay", device: "-", token: "")) else {
            throw RunLockError("the run lock server closed the connection")
        }
        return control
    }

    public func sshEnded(listener: String) -> (count: Int, capSeconds: Int)? {
        guard send(.sshEnded(listener: listener)) else { return nil }
        return awaitUnknownKeys(listener: listener)
    }

    public func remoteRunEnded(listener: String) -> Bool {
        guard send(.remoteRunEnded(listener: listener)) else { return false }
        return awaitUnknownKeys(listener: listener) != nil
    }

    /// 今届いているものだけを見て、EOF なら閉じられた(読んだ行は捨てない = 返事を待つ呼び出しが読む)
    public func issuerClosed() -> Bool {
        lock.withLock { channel.readLine(timeoutMs: 0) == .closed }
    }

    /// 返事の待ちの上限(秒)。根拠: サーバーは手元の待ち受けで即座に答える(判定は表の操作だけ)。数秒答えなければ詰まっている
    static let replyTimeoutMs: Int32 = 10_000

    private func awaitUnknownKeys(listener: String) -> (count: Int, capSeconds: Int)? {
        lock.withLock {
            while true {
                switch channel.readLine(timeoutMs: Self.replyTimeoutMs) {
                case .line(let data):
                    if case .unknownKeys(let name, let count, let cap)? = RunLockMessage.decode(line: data), name == listener {
                        return (count, cap)
                    }
                case .timeout, .closed: return nil
                }
            }
        }
    }

    private func send(_ message: RunLockMessage) -> Bool {
        lock.withLock { RunLockLineChannel.writeAll(descriptor, message.encodedLine()) }
    }
}

/// ssh が終わった後の確かめ直し(中継役)。**不明のキーがあるときだけ**ssh で向こうの run の終わりを確かめる
/// (無いときは何もせず run の終わりを遅らせない)。確かめ直しは発行元が接続を閉じたら・不明のキーが無くなったら・上限で止める
public enum RunLockRecheck {
    public enum Outcome: Equatable, Sendable {
        /// 不明のキーが無い(確かめ直さない)
        case noUnknownKeys
        /// 発行元へつなげなかった・返事が来なかった
        case unreachable
        /// 向こうの run の終わりを確かめて知らせた
        case released
        /// 発行元が接続を閉じた(発行元の仕事は全部終わった)
        case issuerClosed
        /// 上限まで終わりを確かめられなかった(不明のキーは run の終わりまで不明のまま)
        case gaveUp
        /// 中断された(中断の後は誰もそのキーを待てない = 確かめ直しを続けない)
        case interrupted
    }

    /// 確かめ直しの間隔(秒)。根拠: 向こうの run の後始末は実測 2 秒(`RemoteRunDispatcher.remoteRunEndWaitLimitSeconds` の根拠)。
    /// 不明のキーを待つシナリオが居るので遅くしたくないが、1回が ssh の往復なので 2 秒より細かくしても焼くだけ
    public static let intervalSeconds = 2
    /// 上限に足す後始末の猶予(秒)。根拠: 向こうの最後のシナリオが上限(最長の scenarioTimeout)まで走った後の afterAll・tearDownDevice・
    /// 録画の確定・run-teardown.sh。ssh の断の後の後始末の実測(2 秒)に対し、`remoteRunEndWaitLimitSeconds` と同じ 30 秒を見る
    public static let teardownGraceSeconds = 30

    public static func run(listener: String, control: RunLockRelayControl, runEnded: () -> Bool,
                           interrupted: () -> Bool = { false },
                           interval: Duration = .seconds(intervalSeconds),
                           sleep: (Duration) -> Void = { Thread.sleep(forTimeInterval: Double(DurationConversion.milliseconds($0)) / 1000) })
        -> Outcome {
        guard let first = control.sshEnded(listener: listener) else { return .unreachable }
        if first.count == 0 { return .noUnknownKeys }
        let clock = SuspendingClock()
        let deadline = clock.now.advanced(by: .seconds(first.capSeconds + teardownGraceSeconds))
        while true {
            if interrupted() { return .interrupted }
            if control.issuerClosed() { return .issuerClosed }
            if runEnded() { return control.remoteRunEnded(listener: listener) ? .released : .unreachable }
            if clock.now >= deadline { return .gaveUp }
            sleep(interval)
            // シナリオの終わりの報告(`scenarioEnded`)で不明が無くなっていれば止める
            if interrupted() { return .interrupted }
            if let again = control.sshEnded(listener: listener), again.count == 0 { return .noUnknownKeys }
        }
    }
}
