// マシンをまたぐ run の子の側の、親(発行元)との stdin / stdout の通り道。
// - `--work-queue`: シナリオの要求を stdout へ1行、返事を stdin から1行(WorkQueueProtocol)。待たせる = 親が返事を遅らせる
// - `--run-memo-link`(--work-queue も含む): run メモの書き込みと確定の行(RunMemoStore.swift)
// 書き込みは ConsoleOut.out を通す(text run / api run とも stdout の書き手はそこへ集約されていて、1回の write(2) で行が裂けない)。
// **stdin を読むスレッドは1プロセスに1本**(`ParentLink`)。2本で同じ fd を読むと親の行を取り合う。

import Foundation
import Synchronization

/// `--work-queue` の子の stdin(親からの返事)を自分だけの fd へ移し、fd 0 を /dev/null にする。**run の入口で最初に呼ぶ**。
/// stdin を指定せずに起こす子プロセス(`adb shell` など。Process を作る箇所は多数)が fd 0 を受け継いで読むと、親の返事を
/// 横取りする = 親が渡したシナリオをレーンが受け取れず、そのレーンは中断まで止まる(実測2回: 渡した 28 本のうち
/// 子が回したのは 24 本)。移した fd は close-on-exec(子へ渡さない)。何度呼んでも同じ fd を返す
public enum WorkQueueStdin {
    private static let claimed = Mutex<Int32?>(nil)

    public static func claim() -> Int32 {
        claimed.withLock { claimed in
            if let claimed { return claimed }
            let moved = move(STDIN_FILENO)
            claimed = moved
            return moved
        }
    }

    /// fd の中身を close-on-exec の新しい fd へ移し、元の fd を /dev/null にする。複製できなければ元の fd を返す(テストはパイプで呼ぶ)
    static func move(_ fd: Int32) -> Int32 {
        let copy = dup(fd)
        guard copy >= 0 else { return fd }
        _ = fcntl(copy, F_SETFD, FD_CLOEXEC)
        let null = open("/dev/null", O_RDONLY)
        if null >= 0 {
            _ = dup2(null, fd)
            close(null)
        }
        return copy
    }
}

/// stdin(移した fd)を1本のスレッドで読み、1行ごとに登録された読み手へ渡す。端末(ssh -tt の先)ならエコーを切る
public final class ParentLinkReader: Sendable {
    private struct State {
        var started = false
        var eof = false
        var restoreEcho: termios?
        var lineHandlers: [@Sendable (String) -> Void] = []
        var eofHandlers: [@Sendable () -> Void] = []
    }

    public let fd: Int32
    private let state = LockedValue(State())

    public init(fd: Int32) { self.fd = fd }

    /// 1行ごとに読み手のスレッドから呼ばれる。短く返すこと(読み取りを止める)。自分に関係の無い行は読み捨てる
    public func addLineHandler(_ handler: @escaping @Sendable (String) -> Void) {
        state.withLock { $0.lineHandlers.append(handler) }
    }

    /// EOF・読めなくなったときに1回呼ばれる。既に EOF なら即座に呼ぶ
    public func addEOFHandler(_ handler: @escaping @Sendable () -> Void) {
        let already = state.withLock { s -> Bool in
            if s.eof { return true }
            s.eofHandlers.append(handler)
            return false
        }
        if already { handler() }
    }

    /// 読み始める(何度呼んでもよい)。stdin が端末なら送った行が出力へ折り返さないようエコーを切る
    /// (行単位 = canonical のままにして、親の1行を1回の read で受ける)
    public func start() {
        let first = state.withLock { s -> Bool in
            if s.started { return false }
            s.started = true
            return true
        }
        guard first else { return }
        if isatty(fd) != 0 {
            var attributes = termios()
            if tcgetattr(fd, &attributes) == 0 {
                let original = attributes
                attributes.c_lflag &= ~tcflag_t(ECHO)
                if tcsetattr(fd, TCSANOW, &attributes) == 0 {
                    state.withLock { $0.restoreEcho = original }
                }
            }
        }
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "fleetest.parent-link.stdin"
        thread.start()
    }

    /// 端末のエコーを戻す(ssh -tt の先でだけ変えている)。何度呼んでもよい
    public func restoreTerminal() {
        let saved = state.withLock { s -> termios? in
            defer { s.restoreEcho = nil }
            return s.restoreEcho
        }
        guard var saved else { return }
        tcsetattr(fd, TCSANOW, &saved)
    }

    /// 生の read(2) で読む(availableData のループを持たない = 自動解放の溜まりが無い)
    private func readLoop() {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buffer.withUnsafeMutableBytes { Foundation.read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { break }
            pending.append(buffer, count: n)
            while let newline = pending.firstIndex(of: 0x0A) {
                let lineData = pending.subdata(in: pending.startIndex..<newline)
                pending.removeSubrange(pending.startIndex...newline)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                let handlers = state.withLock { $0.lineHandlers }
                for handler in handlers { handler(line) }
            }
        }
        let handlers = state.withLock { s -> [@Sendable () -> Void] in
            s.eof = true
            defer { s.eofHandlers = [] }
            return s.eofHandlers
        }
        for handler in handlers { handler() }
    }
}

/// 親(マシンをまたぐ run の発行元)とつながっている子のプロセスの印と、その run メモの通り道。
/// **`enable()` は run の入口で最初に(stdin を移すため)・読み始めるのは必要になった最初の1回**(`StdioPullSource` か `RunSharedSession`)
/// —— 親へ中継するだけのプロセス(`run --runner <機>`)は stdin をそのまま ssh へ渡すので、読み始めてはいけない
public enum ParentLink {
    private struct Opened: Sendable {
        let reader: ParentLinkReader
        let memoStore: RunMemoStore
    }

    private static let enabled = LockedValue(false)
    private static let opened = LockedValue<Opened?>(nil)

    /// stdin を自分だけの fd へ移し(`WorkQueueStdin`)、このプロセスが親とつながっていると印を立てる
    public static func enable() {
        _ = WorkQueueStdin.claim()
        enabled.value = true
    }

    /// 移した stdin の読み手。enable 済みで fd が移した stdin のときだけ(それ以外は nil = 呼び手が自前の読み手を持つ。テスト)
    static func reader(forDescriptor fd: Int32) -> ParentLinkReader? {
        guard enabled.value, fd == WorkQueueStdin.claim() else { return nil }
        return open().reader
    }

    /// マシンをまたぐ run の子の run メモ(発行元とつながっている1つ)。つながっていなければ nil
    public static func memoStore() -> RunMemoStore? {
        enabled.value ? open().memoStore : nil
    }

    private static func open() -> Opened {
        opened.withLock { current in
            if let current { return current }
            let reader = ParentLinkReader(fd: WorkQueueStdin.claim())
            let link = RunMemoLink(send: { ConsoleOut.out($0) })
            let store = RunMemoStore(link: link)
            reader.addLineHandler { line in link.receive(line: line) }
            reader.start()
            // 読み始めてから知らせる(親の履歴の再送が来ても受けられる)
            link.hello()
            let created = Opened(reader: reader, memoStore: store)
            current = created
            return created
        }
    }
}

public final class StdioPullSource: ScenarioPullSource {
    private struct State {
        var nextReq = 1
        var waiters: [Int: CheckedContinuation<String?, Never>] = [:]
        /// stdin が閉じた(以後の要求は即 nil)
        var eof = false
    }

    private let state = LockedValue(State())
    private let reader: ParentLinkReader
    private let write: @Sendable (String) -> Void

    /// - inputFD / write: テスト用の差し替え口。本番は `WorkQueueStdin.claim()`(移した stdin)と ConsoleOut.out
    public init(inputFD: Int32 = WorkQueueStdin.claim(),
                write: @escaping @Sendable (String) -> Void = { ConsoleOut.out($0) }) {
        self.reader = ParentLink.reader(forDescriptor: inputFD) ?? ParentLinkReader(fd: inputFD)
        self.write = write
        register()
    }

    /// テスト用: 読み手を共有する(同じ stdin に run メモの行と返事が混ざる形を確かめる)
    init(reader: ParentLinkReader, write: @escaping @Sendable (String) -> Void) {
        self.reader = reader
        self.write = write
        register()
    }

    private func register() {
        reader.addLineHandler { [weak self] line in
            if let reply = WorkQueueProtocol.decodeReply(line) { self?.deliver(reply) }
        }
        reader.addEOFHandler { [weak self] in self?.resolveAllWaiters() }
    }

    deinit { restoreTerminal() }

    public func next(platform: String, lane: String) async -> String? {
        reader.start()
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            // 登録してから書く(返事が登録より先に届いても取りこぼさない)・EOF 済みなら即 nil
            let request: Int? = state.withLock { s in
                if s.eof { return nil }
                let req = s.nextReq
                s.nextReq += 1
                s.waiters[req] = continuation
                return req
            }
            guard let request else { continuation.resume(returning: nil); return }
            write(WorkQueueProtocol.encode(
                WorkQueueProtocol.Want(req: request, lane: lane, platform: platform)))
        }
    }

    public func stopWaiting() { resolveAllWaiters() }

    /// 端末のエコーを戻す(ssh -tt の先でだけ変えている)。何度呼んでもよい
    public func restoreTerminal() { reader.restoreTerminal() }

    /// 待っている要求と以後の要求を全部 nil にする(EOF・中断)
    private func resolveAllWaiters() {
        let remaining = state.withLock { s -> [CheckedContinuation<String?, Never>] in
            s.eof = true
            defer { s.waiters = [:] }
            return Array(s.waiters.values)
        }
        for continuation in remaining { continuation.resume(returning: nil) }
    }

    private func deliver(_ reply: WorkQueueProtocol.Reply) {
        let continuation = state.withLock { $0.waiters.removeValue(forKey: reply.req) }
        continuation?.resume(returning: reply.scenarioID)
    }
}
