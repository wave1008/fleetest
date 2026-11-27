// 機械全体で同時 N 個の枠。`SimulatorBootSlots` と同じ方式(枠ごとのロックファイルへ flock(LOCK_EX|LOCK_NB))で、
// クローンもプロセスもまたいで共有する。プロセスが死ねば flock は外れる。fd はプロセスで1回だけ開く。
// 開けなければ fail open(枠なしで通す)。持ち主は `owner` 文字列で識別する(同じ値で2枠は取らない前提)。

import FTCore
import Foundation
import Synchronization

final class MachineWideSlots: Sendable {
    let concurrency: Int
    private let filePrefix: String

    /// 枠が空いてから気付くまでの遅れの上限(200ms)。持ち主の作業(秒〜数十秒)に対して無視できる
    static let pollIntervalNanoseconds: UInt64 = 200_000_000

    private struct State {
        var heldSlots: [Int: String] = [:]
        var cachedFDs: [Int32]?
        var lockDirectory: URL?
    }
    private let state = Mutex(State())

    init(concurrency: Int, filePrefix: String) {
        self.concurrency = concurrency
        self.filePrefix = filePrefix
    }

    /// テストだけが使う置き場の差し替え口。差し替えたら `resetForTesting()` も呼ぶ
    var lockDirectoryForTesting: URL? {
        get { state.withLock { $0.lockDirectory } }
        set { state.withLock { $0.lockDirectory = newValue } }
    }

    private func lockURL(slot: Int, directory: URL?) -> URL {
        if let directory { return directory.appendingPathComponent("\(filePrefix).\(slot)") }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? TemporaryDirectory.url
        return base.appendingPathComponent("fleetest", isDirectory: true)
            .appendingPathComponent("\(filePrefix).\(slot)")
    }

    /// state を握ったまま呼ぶ
    private func descriptors(_ st: inout State) -> [Int32]? {
        if let cached = st.cachedFDs { return cached }
        let first = lockURL(slot: 0, directory: st.lockDirectory)
        try? FileManager.default.createDirectory(
            at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        var fds: [Int32] = []
        for slot in 0..<concurrency {
            let fd = open(lockURL(slot: slot, directory: st.lockDirectory).path,
                          O_CREAT | O_NOFOLLOW | O_RDWR, 0o644)
            guard fd >= 0 else {
                fds.forEach { close($0) }
                return nil
            }
            fds.append(fd)
        }
        st.cachedFDs = fds
        return fds
    }

    /// 待たずに1回だけ試す。ロックファイルを開けないときも true(fail open)。
    /// 同じ fd への別スレッドの LOCK_EX は即成功するので、このプロセスが持つ枠は heldSlots で除く
    func acquireWithoutWaiting(owner: String) -> Bool {
        state.withLock { st in
            guard let fds = descriptors(&st) else { return true }
            for (slot, fd) in fds.enumerated() where st.heldSlots[slot] == nil {
                guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }
                st.heldSlots[slot] = owner
                let text = Array("\(getpid()) \(owner)\n".utf8)
                _ = ftruncate(fd, 0)
                _ = pwrite(fd, text, text.count, 0)
                return true
            }
            return false
        }
    }

    /// 取れるまで待つ(協調スレッドを塞がない)。待ちの上限は置かない(持ち主が死ねば flock が外れる)。
    /// 取り消されたら CancellationError。待ちに入ったときと取れたときに1行ずつ `log` へ出す
    func acquire(owner: String, what: String, log: (String) -> Void) async throws {
        if acquireWithoutWaiting(owner: owner) { return }
        let start = Date()
        let holders = owners()
        log("waiting for \(what) slot (\(concurrency) at a time on this machine; held by: "
            + (holders.isEmpty ? "unknown" : holders.joined(separator: ", ")) + ")")
        while !acquireWithoutWaiting(owner: owner) {
            try await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
        }
        log("got \(what) slot after \(Int(Date().timeIntervalSince(start))) s")
    }

    /// `owner` で取った枠を返す(取っていなければ何もしない)
    func release(owner: String) {
        state.withLock { st in
            guard let fds = descriptors(&st),
                  let slot = st.heldSlots.first(where: { $0.value == owner })?.key else { return }
            st.heldSlots[slot] = nil
            _ = ftruncate(fds[slot], 0)
            _ = flock(fds[slot], LOCK_UN)
        }
    }

    /// 枠を取って body を走らせ、完了でも throw でも返す
    func withSlot<T>(owner: String, what: String, log: (String) -> Void,
                     _ body: () async throws -> T) async throws -> T {
        try await acquire(owner: owner, what: what, log: log)
        defer { release(owner: owner) }
        return try await body()
    }

    /// 各枠のファイルに書かれた `pid owner`(ログ用)
    func owners() -> [String] {
        let directory = state.withLock { $0.lockDirectory }
        return (0..<concurrency).compactMap { slot in
            guard let text = try? String(contentsOf: lockURL(slot: slot, directory: directory), encoding: .utf8)
            else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    func resetForTesting() {
        state.withLock {
            $0.cachedFDs?.forEach { close($0) }
            $0.cachedFDs = nil
            $0.heldSlots = [:]
        }
    }
}

/// in-app ブリッジの新規注入(と冷えたシミュレータのブート)を含む台の同時起動枠。機械全体で共有する
enum InAppLaunchSlots {
    /// 同時に起動してよい台数(ユーザー決定の「一括起動は同時2台」)。8台同時の terminate→launch+注入で
    /// シミュレータの画面凍結クラスタが同日2回発生した(`BridgeProvisioner` の起動段の注記)。
    /// 重なる複数の run・子プロセスの合算でも2台に収めるため機械全体の枠にする。設定の口は置かない
    static let concurrency = 2
    static let shared = MachineWideSlots(concurrency: concurrency, filePrefix: "inapp-launch.lock")
}
