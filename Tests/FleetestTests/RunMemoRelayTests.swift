// マシンをまたぐ run の発行元の run メモの中継(RunMemoRelay。DR-208)と、子へ渡す口の配線を固定する。
// 破ると: 動的でない形(--broadcast・計測・静的な割り振り)の子で run メモがマシンごとに割れる / 子の `{"ftWork"` の行が
// 表示や NDJSON に混ざる / 子の stdin を /dev/null にしたまま発行元の返事が届かない。

import XCTest
import FTCore
@testable import fleetest

final class RunMemoRelayTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func piece(src: String, lid: Int, d: String = "eyJrIjoiYSIsInYiOiJiIn0=") -> String {  // {"k":"a","v":"b"} = 読める中身(読めない断片の組には番号を振らない)
        WorkQueueProtocol.encode(WorkQueueProtocol.MemoPiece(src: src, lid: lid, seq: nil, i: 0, n: 1, d: d))
    }

    /// 子ごとの stdin に見立てたパイプ。書き込み口を付けて、読み出し側を返す
    private func attachedWriter() -> (writer: ChildStdinWriter, reader: FileHandle) {
        let pipe = Pipe()
        let writer = ChildStdinWriter()
        writer.attach(pipe.fileHandleForWriting)
        return (writer, pipe.fileHandleForReading)
    }

    /// 読み出し側に溜まった行(書き込みが済んでから呼ぶ)
    private func lines(from handle: FileHandle) -> [String] {
        // 非ブロッキングで溜まった分だけ読む(availableData は空のパイプで永久に待つ = 届かない変異でテストが止まる)
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// 発行元の通し番号つきで、起動を知らせた子(書いた子にも)へ配る。動的な割り振りの配り手が無い形でも同じ
    func testMemoLinesAreNumberedAndRelayedToEveryJoinedChildWithoutADispatcher() throws {
        let zero = attachedWriter()
        let one = attachedWriter()
        let relay = RunMemoRelay(writers: [0: zero.writer, 1: one.writer], gateMode: .startOnHello)
        let hello = { (src: String) in WorkQueueProtocol.encode(WorkQueueProtocol.MemoHello(src: src)) }
        XCTAssertTrue(relay.intercept(line: hello("a"), entry: 0, dispatcher: nil))
        XCTAssertTrue(relay.intercept(line: hello("b"), entry: 1, dispatcher: nil))
        XCTAssertTrue(relay.intercept(line: piece(src: "b", lid: 1) + "\r", entry: 1, dispatcher: nil))
        zero.writer.flush()
        one.writer.flush()
        for reader in [zero.reader, one.reader] {
            let received = lines(from: reader).compactMap(WorkQueueProtocol.decodeMemoPiece)
            XCTAssertEqual(received.map(\.seq), [1])
            XCTAssertEqual(received.first?.src, "b")
        }
    }

    /// 子の `{"ftWork"` の行は全部消費する(表示・NDJSON へ出さない)。配り手の無い形の `want` は答えずに捨てる。ログ行は消費しない
    func testEveryWorkLineIsConsumedButOrdinaryLinesAreNot() {
        let relay = RunMemoRelay(writers: [:], gateMode: .startOnHello)
        let want = WorkQueueProtocol.encode(WorkQueueProtocol.Want(req: 1, lane: "a", platform: "ios"))
        XCTAssertTrue(relay.intercept(line: want, entry: 0, dispatcher: nil))
        XCTAssertTrue(relay.intercept(line: #"{"ftWork":{"unknown":true}}"#, entry: 0, dispatcher: nil))
        XCTAssertFalse(relay.intercept(line: "✅ Login.S0010", entry: 0, dispatcher: nil))
        XCTAssertFalse(relay.intercept(line: #"{"kind":"step"}"#, entry: 0, dispatcher: nil))
    }

    /// 配り手がある形では、メモの行は hub・`want` は配り手へ(同じ口を共有する)
    func testWantStillGoesToTheDispatcherWhenOneExists() throws {
        let zero = attachedWriter()
        let sent = LockedValue<[String]>([])
        let dispatcher = DynamicDispatcher(
            scenarios: [DynamicSplit.Scenario(id: "A.S0010", variant: nil, platform: "ios")],
            estimateMs: { _, _ in 1000 }, lpt: false,
            send: { entry, reply in sent.withLock { $0.append("\(entry):\(WorkQueueProtocol.encode(reply))") } })
        let relay = RunMemoRelay(writers: [0: zero.writer], gateMode: .startOnHello)
        let want = WorkQueueProtocol.encode(WorkQueueProtocol.Want(req: 1, lane: "a", platform: "ios"))
        XCTAssertTrue(relay.intercept(line: want, entry: 0, dispatcher: dispatcher))
        zero.writer.flush()
        let answered = lines(from: zero.reader).compactMap(WorkQueueProtocol.decodeReply)
        XCTAssertEqual(answered.first?.unit, ScenarioUnitKey(id: "A.S0010", variant: nil), "want が配り手へ渡っていない")
        XCTAssertTrue(relay.intercept(line: piece(src: "a", lid: 1), entry: 0, dispatcher: dispatcher))
        XCTAssertEqual(relay.hub.confirmedCount, 1, "メモの行が hub へ渡っていない")
    }

    /// hub の配りと配り手の返事は同じ子の書き手へ呼んだ順に積まれる(別のキューを挟むと返事が書き込みを追い越す)
    func testHubWritesAndDispatcherRepliesReachTheChildInTheOrderTheyWereQueued() {
        let zero = attachedWriter()
        let relay = RunMemoRelay(writers: [0: zero.writer], gateMode: .startOnHello)
        XCTAssertTrue(relay.intercept(
            line: WorkQueueProtocol.encode(WorkQueueProtocol.MemoHello(src: "a")), entry: 0, dispatcher: nil))
        relay.hub.seedConfirmed([.write(key: "k", value: "v")])
        zero.writer.write(line: "REPLY")
        relay.hub.seedConfirmed([.write(key: "k", value: "w")])
        zero.writer.write(line: "REPLY2")
        zero.writer.flush()
        let all = lines(from: zero.reader)
        XCTAssertEqual(all.count, 5, "\(all)")
        XCTAssertEqual(WorkQueueProtocol.decodeStartSignal(all[0]), .start)
        XCTAssertEqual(WorkQueueProtocol.decodeMemoPiece(all[1])?.seq, 1)
        XCTAssertEqual(all[2], "REPLY")
        XCTAssertEqual(WorkQueueProtocol.decodeMemoPiece(all[3])?.seq, 2)
        XCTAssertEqual(all[4], "REPLY2")
    }

    /// 起動の知らせを受けた子へ、履歴の後ろに開始の行を送る(開始を決める呼び出しの配線が無い既定の形 = 子が待って止まらない)
    func testHelloIsAnsweredWithTheStartLine() {
        let zero = attachedWriter()
        let relay = RunMemoRelay(writers: [0: zero.writer], gateMode: .startOnHello)
        XCTAssertTrue(relay.intercept(
            line: WorkQueueProtocol.encode(WorkQueueProtocol.MemoHello(src: "a")), entry: 0, dispatcher: nil))
        zero.writer.flush()
        let received = lines(from: zero.reader).compactMap(WorkQueueProtocol.decodeStartSignal)
        XCTAssertEqual(received, [.start])
    }

    // MARK: - ChildStdinWriter(独立した直列のキュー)

    /// attach の前に積んだ行は捨てず、attach で積んだ順に流す。その後の行も順序どおり
    func testWriterKeepsLinesWrittenBeforeAttachAndFlushesThemInOrder() {
        let pipe = Pipe()
        let writer = ChildStdinWriter()
        writer.write(line: "one")
        writer.write(line: "two")
        writer.attach(pipe.fileHandleForWriting)
        writer.write(line: "three")
        writer.flush()
        XCTAssertEqual(lines(from: pipe.fileHandleForReading), ["one", "two", "three"])
    }

    /// 書き込みは呼んだスレッドをブロックしない: 読み手の居ない詰まったパイプへ大量に書いても write(line:) は戻る
    func testWriteDoesNotBlockTheCallerWhenThePipeIsFull() {
        let pipe = Pipe()
        let writer = ChildStdinWriter()
        writer.attach(pipe.fileHandleForWriting)
        let line = String(repeating: "x", count: 900)
        let started = Date()
        for _ in 0..<2000 { writer.write(line: line) }   // 約 1.8 MB = パイプの容量(64 KB 前後)を大きく超える
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0, "呼んだスレッドが詰まったパイプで止まっている")
        // 後始末: 読み手を閉じて詰まった書き込みを EPIPE で終わらせる
        try? pipe.fileHandleForReading.close()
        writer.close()
        writer.flush()
    }

    /// 書き手ごとに独立: 1つの子の書き込みが詰まっても、別の子の書き手は流れる
    func testWritersAreIndependentOfEachOther() {
        let stuck = Pipe()
        let stuckWriter = ChildStdinWriter()
        stuckWriter.attach(stuck.fileHandleForWriting)
        let line = String(repeating: "x", count: 900)
        for _ in 0..<2000 { stuckWriter.write(line: line) }
        let healthy = attachedWriter()
        healthy.writer.write(line: "hello")
        healthy.writer.flush()
        XCTAssertEqual(lines(from: healthy.reader), ["hello"])
        try? stuck.fileHandleForReading.close()
        stuckWriter.close()
        stuckWriter.flush()
    }

    /// 閉じるのもキューの中: 積んだ行を書いてから閉じ、閉じた後の行は捨てる(attach 前に閉じても fd は残さない)
    func testCloseRunsInTheQueueAfterPendingWrites() {
        let pipe = Pipe()
        let writer = ChildStdinWriter()
        writer.attach(pipe.fileHandleForWriting)
        writer.write(line: "last")
        writer.close()
        writer.write(line: "dropped")
        writer.flush()
        XCTAssertEqual(lines(from: pipe.fileHandleForReading), ["last"])
        var byte: UInt8 = 0
        XCTAssertEqual(read(pipe.fileHandleForReading.fileDescriptor, &byte, 1), 0, "書き込み端が閉じていない(EOF にならない)")
    }

    // MARK: - 子へ渡す引数と stdin の配線

    /// 親とつながった子は、手元で走ると決まった後(中継役の分岐より後)・ビルドの前に起動を知らせ、最初のワーカーの前に開始を待つ。
    /// 取りやめた子は終了コード 1 で終わる(run / api run の両方)
    func testLinkedChildAnnouncesEarlyWaitsForStartAndExitsOneWhenCancelled() throws {
        for file in ["Fleetest", "ApiRunCommand"] {
            let text = try source("Sources/fleetest/\(file).swift")
            let announce = try XCTUnwrap(text.range(of: "ParentLink.announce()"), "\(file): 起動の知らせを出していない")
            let relay = try XCTUnwrap(text.range(of: "try await dispatchToRemoteHost("), file)
            XCTAssertLessThan(relay.lowerBound, announce.lowerBound, "\(file): 中継役の分岐より前で知らせている(stdin を ssh へ渡せなくなる)")
            // 取りやめの理由は RunSummary(`startCancelled`)から読む = static の ParentLink には残さない
            // (中断で開始待ちを抜けた後に届いた取りやめの行を、取りやめと読まない)
            XCTAssertFalse(text.contains("ParentLink.startCancelReason"), "\(file): static の取りやめの印を判定に使っている")
            XCTAssertTrue(text.contains("startCancelled")
                          && (text.contains("nothingRan") || text.contains("|| hookCancelReason != nil { throw ExitCode(1) }")),
                          "\(file): 取りやめた子が終了コード 1 にならない")
        }
        for file in ["ProfileRunner", "ApiRunCommand"] {
            let text = try source("Sources/fleetest/\(file).swift")
            XCTAssertTrue(text.contains("startGate: ParentLink.startGate()"), "\(file): 開始の行を待たずに流し始める")
        }
    }

    func testChildArgsCarryTheMemoLinkOnlyWhenAsked() {
        func args(link: Bool) -> [String] {
            DeviceMachineRunner.childArgs(
                project: "E2E", host: "M1Ultra", profile: "p", deviceNames: ["iPhone-01"], deviceMachine: "M1Ultra",
                scenarios: ["Warm.up"], folders: [], noLPT: false, lptHistoryRuns: nil, performanceMode: false,
                forceLock: false, remoteDir: nil, remoteTimeout: nil, quiet: true, junitPath: nil,
                broadcast: true, runMemoLink: link)
        }
        XCTAssertTrue(args(link: true).contains("--run-memo-link"))
        XCTAssertFalse(args(link: false).contains("--run-memo-link"))
        XCTAssertFalse(args(link: true).contains("--work-queue"), "run メモの通り道は --work-queue を含意させない(broadcast と併用できない)")
    }

    func testApiFanoutBuildArgsCarryTheMemoLinkOnlyWhenAsked() {
        func args(link: Bool) -> [String] {
            ApiRunMachineFanout.buildArgs(
                project: "E2E", profileName: "p",
                group: DeviceMachineRunner.Group(machine: "M1Ultra", deviceNames: ["Pixel"], platforms: ["android"]),
                units: [ScenarioUnitKey(id: "A.S0010", variant: nil)],
                options: ApiRunMachineFanout.Options(
                    defaultTimeout: nil, scenarioTimeout: nil, noLPT: false, lptHistoryRuns: nil,
                    performanceMode: false, remoteDir: nil, remoteTimeout: nil, waitLock: nil),
                runGroup: "g", runMemoLink: link)
        }
        XCTAssertTrue(args(link: true).contains("--run-memo-link"))
        XCTAssertFalse(args(link: false).contains("--run-memo-link"))
    }

    /// 発行元の3経路は、どの形の子にも `--run-memo-link` を渡し、stdin の書き込み口を子ごとに持つ(動的でない形でも)
    func testEveryFanoutOpensTheMemoLinkForItsChildren() throws {
        for file in ["DeviceMachineRunner", "ApiRunMachineFanout", "MultiTargetRunner"] {
            let text = try source("Sources/fleetest/\(file).swift")
            XCTAssertTrue(text.contains("runMemoLink: true"), "\(file): 子に --run-memo-link を渡していない")
            XCTAssertTrue(text.contains("RunMemoRelay"), "\(file): 子の行を run メモの中継に通していない")
        }
        // 書き込み口が動的な割り振りのときだけになっていない(静的・broadcast・計測の子にも stdin を繋ぐ)
        for file in ["DeviceMachineRunner", "ApiRunMachineFanout"] {
            let text = try source("Sources/fleetest/\(file).swift")
            XCTAssertFalse(text.contains("dynamicPlan == nil ? [:]"), "\(file): 書き込み口が動的な割り振りの子だけになっている")
        }
    }

    /// 中継役(`run --runner <機>`)は、親とつながる子なら移した stdin を ssh へ渡す(--work-queue だけに限らない)
    func testRemoteRelayHandsStdinToSSHForEveryLinkedChild() throws {
        let text = try source("Sources/fleetest/RemoteRunDispatcher.swift")
        XCTAssertTrue(text.contains("process.standardInput = linkedToParent"))
        XCTAssertFalse(text.contains("process.standardInput = workQueue"))
        XCTAssertEqual(text.components(separatedBy: "linkedToParent: workQueue || runMemoLink").count - 1, 2,
                       "run / api run の両方の入口が共通本体へ linkedToParent を渡している必要がある")
        let start = try XCTUnwrap(text.range(of: "private func performDispatch("))
        let end = try XCTUnwrap(text.range(of: "\n    }\n", range: start.upperBound..<text.endIndex))
        let shared = text[start.lowerBound..<end.upperBound]
        XCTAssertEqual(shared.components(separatedBy: "linkedToParent: linkedToParent").count - 1, 1,
                       "共通本体が受け取った linkedToParent を runRemoteAndRelay へ渡している必要がある")
        for entry in ["func dispatch(", "func dispatchApi("] {
            let entryStart = try XCTUnwrap(text.range(of: entry), entry)
            let entryEnd = try XCTUnwrap(text.range(of: "\n    }\n", range: entryStart.upperBound..<text.endIndex), entry)
            XCTAssertTrue(text[entryStart.lowerBound..<entryEnd.upperBound].contains("try await performDispatch("), entry)
        }
        let options = try source("Sources/fleetest/RunCommonOptions.swift")
        XCTAssertTrue(options.contains("var linkedToParent: Bool { workQueue || runMemoLink }"))
    }

    /// `--fleet` は run メモをマシンをまたいで1つにしない。開始時の1行(英語)を出す
    func testFleetAnnouncesPerMachineRunMemo() throws {
        XCTAssertEqual(FleetRunner.runMemoPerMachineNotice,
                       "ℹ️ writeRunMemo values are shared per machine in a --fleet run, not across machines")
        let text = try source("Sources/fleetest/FleetRunner.swift")
        XCTAssertEqual(text.components(separatedBy: "log(runMemoPerMachineNotice)").count - 1, 2)
    }
}
