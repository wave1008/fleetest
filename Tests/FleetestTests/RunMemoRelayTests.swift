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

    private func piece(src: String, lid: Int, d: String = "e2s6MX0=") -> String {
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
        let relay = RunMemoRelay(writers: [0: zero.writer, 1: one.writer])
        let hello = { (src: String) in WorkQueueProtocol.encode(WorkQueueProtocol.MemoHello(src: src)) }
        XCTAssertTrue(relay.intercept(line: hello("a"), entry: 0, dispatcher: nil))
        XCTAssertTrue(relay.intercept(line: hello("b"), entry: 1, dispatcher: nil))
        XCTAssertTrue(relay.intercept(line: piece(src: "b", lid: 1) + "\r", entry: 1, dispatcher: nil))
        relay.hub.flush()
        for reader in [zero.reader, one.reader] {
            let received = lines(from: reader).compactMap(WorkQueueProtocol.decodeMemoPiece)
            XCTAssertEqual(received.map(\.seq), [1])
            XCTAssertEqual(received.first?.src, "b")
        }
    }

    /// 子の `{"ftWork"` の行は全部消費する(表示・NDJSON へ出さない)。配り手の無い形の `want` は答えずに捨てる。ログ行は消費しない
    func testEveryWorkLineIsConsumedButOrdinaryLinesAreNot() {
        let relay = RunMemoRelay(writers: [:])
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
            scenarios: [DynamicSplit.Scenario(id: "A.S0010", platform: "ios")],
            estimateMs: { _, _ in 1000 }, lpt: false,
            send: { entry, reply in sent.withLock { $0.append("\(entry):\(WorkQueueProtocol.encode(reply))") } })
        let relay = RunMemoRelay(writers: [0: zero.writer])
        let want = WorkQueueProtocol.encode(WorkQueueProtocol.Want(req: 1, lane: "a", platform: "ios"))
        XCTAssertTrue(relay.intercept(line: want, entry: 0, dispatcher: dispatcher))
        let answered = lines(from: zero.reader).compactMap(WorkQueueProtocol.decodeReply)
        XCTAssertEqual(answered.first?.scenarioID, "A.S0010", "want が配り手へ渡っていない")
        XCTAssertTrue(relay.intercept(line: piece(src: "a", lid: 1), entry: 0, dispatcher: dispatcher))
        XCTAssertEqual(relay.hub.confirmedCount, 1, "メモの行が hub へ渡っていない")
    }

    // MARK: - 子へ渡す引数と stdin の配線

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
                scenarioIDs: ["A.S0010"],
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
                       "run / api run の両方の中継が --run-memo-link を渡している必要がある")
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
