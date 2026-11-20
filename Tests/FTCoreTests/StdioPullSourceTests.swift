import XCTest
@testable import FTCore

final class StdioPullSourceTests: XCTestCase {

    private func makePipe() -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        let (r, w) = (fds[0], fds[1])
        addTeardownBlock { close(r); close(w) }
        return (r, w)
    }

    private func send(_ text: String, to fd: Int32) {
        let bytes = Array((text + "\n").utf8)
        XCTAssertEqual(Foundation.write(fd, bytes, bytes.count), bytes.count)
    }

    /// 要求の行が出てから返事を返す。返事の req で待っている要求へ届く
    func testWantLineIsWrittenAndReplyResolvesTheMatchingRequest() async {
        let input = makePipe()
        let written = LockedValue<[String]>([])
        let source = StdioPullSource(inputFD: input.read, write: { line in written.withLock { $0.append(line) } })
        async let id = source.next(platform: "ios", lane: "iPhone 17")
        for _ in 0..<200 where written.withLock({ $0.isEmpty }) { try? await Task.sleep(for: .milliseconds(10)) }
        let lines = written.withLock { $0 }
        XCTAssertEqual(lines.count, 1)
        let want = lines.first.flatMap(WorkQueueProtocol.decodeWant)
        XCTAssertEqual(want?.lane, "iPhone 17")
        XCTAssertEqual(want?.platform, "ios")
        send(WorkQueueProtocol.encode(WorkQueueProtocol.Reply(req: want?.req ?? -1, id: "A.S0010")), to: input.write)
        let resolved = await id
        XCTAssertEqual(resolved, "A.S0010")
    }

    /// 返事の順序が要求と逆でも req で振り分ける
    func testRepliesAreRoutedByRequestNumber() async {
        let input = makePipe()
        let written = LockedValue<[String]>([])
        let source = StdioPullSource(inputFD: input.read, write: { line in written.withLock { $0.append(line) } })
        async let first = source.next(platform: "android", lane: "a")
        for _ in 0..<200 where written.withLock({ $0.count < 1 }) { try? await Task.sleep(for: .milliseconds(10)) }
        async let second = source.next(platform: "android", lane: "b")
        for _ in 0..<200 where written.withLock({ $0.count < 2 }) { try? await Task.sleep(for: .milliseconds(10)) }
        let wants = written.withLock { $0 }.compactMap(WorkQueueProtocol.decodeWant)
        XCTAssertEqual(wants.map(\.lane), ["a", "b"])
        send(WorkQueueProtocol.encode(WorkQueueProtocol.Reply(req: wants[1].req, id: "B")), to: input.write)
        send(WorkQueueProtocol.encode(WorkQueueProtocol.Reply(req: wants[0].req, none: true)), to: input.write)
        let (a, b) = await (first, second)
        XCTAssertNil(a)
        XCTAssertEqual(b, "B")
    }

    /// stdin の EOF で待っている要求も以後の要求も nil(もう無い)
    func testEOFResolvesWaitingAndFutureRequestsWithNil() async {
        let input = makePipe()
        let written = LockedValue<[String]>([])
        let source = StdioPullSource(inputFD: input.read, write: { line in written.withLock { $0.append(line) } })
        async let waiting = source.next(platform: "ios", lane: "a")
        for _ in 0..<200 where written.withLock({ $0.isEmpty }) { try? await Task.sleep(for: .milliseconds(10)) }
        close(input.write)
        let first = await waiting
        XCTAssertNil(first)
        let later = await source.next(platform: "ios", lane: "a")
        XCTAssertNil(later)
        XCTAssertEqual(written.withLock { $0.count }, 1, "EOF 後の要求は書かずに nil にする")
    }

    /// 中断(stopWaiting)で、返事の来ない要求も以後の要求も nil になる(親の返事を当てにしない)
    func testStopWaitingResolvesWaitingAndFutureRequestsWithoutAReply() async {
        let input = makePipe()
        let written = LockedValue<[String]>([])
        let source = StdioPullSource(inputFD: input.read, write: { line in written.withLock { $0.append(line) } })
        // 解けないと永遠に待つので、2 秒で打ち切って "timeout" を返す(タスクグループは子が終わるまで抜けないので使わない)
        func nextOrTimeout() async -> String? {
            let box = LockedValue<CheckedContinuation<String?, Never>?>(nil)
            return await withCheckedContinuation { continuation in
                box.withLock { $0 = continuation }
                Task {
                    let value = await source.next(platform: "android", lane: "a")
                    box.withLock { $0?.resume(returning: value); $0 = nil }
                }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    box.withLock { $0?.resume(returning: "timeout"); $0 = nil }
                }
            }
        }
        async let waiting = nextOrTimeout()
        for _ in 0..<200 where written.withLock({ $0.isEmpty }) { try? await Task.sleep(for: .milliseconds(10)) }
        source.stopWaiting()
        let first = await waiting
        XCTAssertNil(first, "待っている要求が中断で解けない")
        let later = await nextOrTimeout()
        XCTAssertNil(later, "中断後の要求が nil にならない")
        XCTAssertEqual(written.withLock { $0.count }, 1, "中断後の要求は書かずに nil にする")
    }

    /// stdin の移し替え: 移した先で親の返事を読め、元の fd は /dev/null(子プロセスが受け継いでも何も読めない)、移した先は子へ渡らない
    func testMoveKeepsTheStreamOnAPrivateCloseOnExecDescriptorAndBlanksTheOriginal() {
        let pipeFDs = makePipe()
        let original = dup(pipeFDs.read)   // 「stdin」役(テストのプロセスの fd 0 は触らない)
        XCTAssertGreaterThanOrEqual(original, 0)
        defer { close(original) }
        let moved = WorkQueueStdin.move(original)
        defer { if moved != original { close(moved) } }
        XCTAssertNotEqual(moved, original, "複製していない")
        XCTAssertEqual(fcntl(moved, F_GETFD) & FD_CLOEXEC, FD_CLOEXEC, "移した fd が子へ受け継がれる")
        send("reply", to: pipeFDs.write)
        var buffer = [UInt8](repeating: 0, count: 16)
        let n = read(moved, &buffer, buffer.count)
        XCTAssertEqual(n > 0 ? String(decoding: buffer[0..<n], as: UTF8.self) : "", "reply\n", "移した先で読めない")
        XCTAssertEqual(read(original, &buffer, buffer.count), 0, "元の fd が /dev/null になっていない(子プロセスが返事を読める)")
    }

    /// 要求と無関係な行(他の JSON・壊れた行)は無視する
    func testUnrelatedInputLinesAreIgnored() async {
        let input = makePipe()
        let written = LockedValue<[String]>([])
        let source = StdioPullSource(inputFD: input.read, write: { line in written.withLock { $0.append(line) } })
        async let id = source.next(platform: "ios", lane: "a")
        for _ in 0..<200 where written.withLock({ $0.isEmpty }) { try? await Task.sleep(for: .milliseconds(10)) }
        let req = written.withLock { $0 }.first.flatMap(WorkQueueProtocol.decodeWant)?.req ?? -1
        send(#"{"kind":"step"}"#, to: input.write)
        send("garbage", to: input.write)
        send(WorkQueueProtocol.encode(WorkQueueProtocol.Reply(req: req + 100, id: "STRAY")), to: input.write)
        send(WorkQueueProtocol.encode(WorkQueueProtocol.Reply(req: req, id: "A")), to: input.write)
        let resolved = await id
        XCTAssertEqual(resolved, "A")
    }

    /// 同じ stdin に返事と run メモの確定が混ざっても、読み手1本が振り分ける(返事は待っている要求へ・確定は store へ)。
    /// 2本で同じ fd を読むと親の行を取り合う
    func testOneReaderServesBothRepliesAndRunMemoConfirmations() async {
        let input = makePipe()
        let reader = ParentLinkReader(fd: input.read)
        let written = LockedValue<[String]>([])
        let source = StdioPullSource(reader: reader, write: { line in written.withLock { $0.append(line) } })
        let link = RunMemoLink(source: "me", send: { _ in }, warn: { _ in })
        let store = RunMemoStore(link: link)
        reader.addLineHandler { line in link.receive(line: line) }
        async let id = source.next(platform: "ios", lane: "a")
        for _ in 0..<200 where written.withLock({ $0.isEmpty }) { try? await Task.sleep(for: .milliseconds(10)) }
        let req = written.withLock { $0 }.first.flatMap(WorkQueueProtocol.decodeWant)?.req ?? -1
        let pieces = RunMemoWire.pieces(for: .write(key: "k", value: "v"))
        send(WorkQueueProtocol.encode(WorkQueueProtocol.MemoPiece(
            src: "other", lid: 1, seq: 1, i: 0, n: pieces.count, d: pieces[0])), to: input.write)
        send(WorkQueueProtocol.encode(WorkQueueProtocol.Reply(req: req, id: "A")), to: input.write)
        let resolved = await id
        XCTAssertEqual(resolved, "A")
        for _ in 0..<200 where store.snapshot().isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.snapshot(), ["k": ["v"]])
    }

    // MARK: - 開始の門(ParentStartGate。RR-8.4)

    private static func waitOrTimeout(_ gate: ParentStartGate) async -> String {
        let box = LockedValue<CheckedContinuation<String, Never>?>(nil)
        return await withCheckedContinuation { continuation in
            box.withLock { $0 = continuation }
            Task {
                let signal = await gate.wait()
                box.withLock { $0?.resume(returning: "\(signal)"); $0 = nil }
            }
            Task {
                try? await Task.sleep(for: .seconds(3))
                box.withLock { $0?.resume(returning: "timeout"); $0 = nil }
            }
        }
    }

    /// 開始の行が来るまで待ち、来たら解ける。同じ stdin に混ざった他の行は読み捨てる
    func testGateWaitsForTheStartLineAndIgnoresOtherLines() async {
        let input = makePipe()
        let reader = ParentLinkReader(fd: input.read)
        let gate = ParentStartGate()
        gate.attach(to: reader)
        reader.start()
        async let outcome = Self.waitOrTimeout(gate)
        send(WorkQueueProtocol.encode(WorkQueueProtocol.Reply(req: 1, id: "A")), to: input.write)
        send("garbage", to: input.write)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(gate.current, "開始の行が来る前に解けている")
        send(WorkQueueProtocol.encode(WorkQueueProtocol.StartSignal.start), to: input.write)
        let result = await outcome
        XCTAssertEqual(result, "start")
    }

    /// 取りやめの行は理由つきで解ける。最初に決まった結果が全て(後の開始・EOF は無視)
    func testGateCancelCarriesTheReasonAndTheFirstOutcomeWins() async {
        let input = makePipe()
        let reader = ParentLinkReader(fd: input.read)
        let gate = ParentStartGate()
        gate.attach(to: reader)
        reader.start()
        send(WorkQueueProtocol.encode(WorkQueueProtocol.StartSignal.cancel(reason: "beforeRun() failed")), to: input.write)
        send(WorkQueueProtocol.encode(WorkQueueProtocol.StartSignal.start), to: input.write)
        close(input.write)
        let result = await Self.waitOrTimeout(gate)
        XCTAssertEqual(result, "cancel(reason: \"beforeRun() failed\")")
        let again = await gate.wait()
        XCTAssertEqual(again, .cancel(reason: "beforeRun() failed"))
    }

    /// 開始の行が来ないまま stdin が閉じたら(親が死んだ)、取りやめとして解ける = 待ち続けて止まらない
    func testGateResolvesAsCancelWhenTheLinkClosesBeforeTheStart() async {
        let input = makePipe()
        let reader = ParentLinkReader(fd: input.read)
        let gate = ParentStartGate()
        gate.attach(to: reader)
        reader.start()
        async let outcome = Self.waitOrTimeout(gate)
        close(input.write)
        let result = await outcome
        XCTAssertTrue(result.hasPrefix("cancel("), result)
    }

    /// 開始の行が先に届いていても、その後に待ち始めた側が取りこぼさない
    func testGateReturnsAnAlreadyDecidedOutcomeImmediately() async {
        let gate = ParentStartGate()
        gate.receive(line: WorkQueueProtocol.encode(WorkQueueProtocol.StartSignal.start))
        let result = await gate.wait()
        XCTAssertEqual(result, .start)
        XCTAssertEqual(gate.current, .start)
    }
}
