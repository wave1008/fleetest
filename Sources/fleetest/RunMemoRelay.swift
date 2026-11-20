// RunMemoRelay.swift
// マシンをまたぐ run の発行元(DeviceMachineRunner / ApiRunMachineFanout / MultiTargetRunner の対象ごと)の側で、
// run メモ(DR-208)の行を子との間で中継する口。正本は FTCore.RunMemoHub(通し番号を振って全マシンへ配り返す)。
// - 子の stdin への書き込み口(ChildStdinWriter)は子ごとに1つ。**動的な割り振り・`--broadcast`・レスポンス計測・静的な割り振りの
//   どの形でも、子には `--run-memo-link` を渡してこの通り道を開ける**(動的な割り振りの子は `--work-queue` の行も同じ口に載る)
// - 子の stdout の `{"ftWork"` の行は全部ここで消費する(表示にも NDJSON にも出さない)。メモの行は hub、
//   `want` は配り手(DynamicDispatcher)へ。配り手が無い形の `want` は答えずに読み捨てる(子が送る形は無いが、止めない)

import FTCore
import Foundation

struct RunMemoRelay: Sendable {
    let hub: RunMemoHub
    let writers: [Int: ChildStdinWriter]

    /// `writers` のキー = 子のエントリ番号(DynamicDispatcher のエントリと同じ)。対象が1つなので hub の鍵の target は "" 。
    /// `gateMode`: `startOnHello` = 起動の知らせを受けたらすぐ開始の行を送る(`@RunHooks` が無い run)・`awaitDecision` = beforeRun の結果が出るまで保留する
    init(writers: [Int: ChildStdinWriter], gateMode: RunMemoHub.GateMode) {
        self.writers = writers
        hub = RunMemoHub(mode: gateMode, send: { child, lines in
            writers[child.entry]?.write(line: lines.joined(separator: "\n"))
        })
    }

    /// 子の標準出力の1行を受ける共通の口。戻り値 true = 消費した(表示しない)。行末の `\r`(pty)は落としてから見る
    func intercept(line: String, entry: Int, dispatcher: DynamicDispatcher?) -> Bool {
        Self.intercept(line: line, hub: hub, child: RunMemoHub.Child(target: "", entry: entry),
                       dispatcher: dispatcher, writer: writers[entry])
    }

    /// 書き込み口を子ごとの表で持たない発行元(MultiTargetRunner = 対象ごとに hub を持つ)用の同じ判定
    static func intercept(line: String, hub: RunMemoHub, child: RunMemoHub.Child,
                          dispatcher: DynamicDispatcher?, writer: ChildStdinWriter?) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WorkQueueProtocol.isWorkLine(trimmed) else { return false }
        if hub.receive(line: trimmed, from: child) { return true }
        if let dispatcher, let writer {
            return dispatcher.intercept(line: trimmed, entry: child.entry, writer: writer)
        }
        return true
    }

    /// 子が終わった(以後は配らない)
    func childExited(entry: Int) { hub.entryExited(RunMemoHub.Child(target: "", entry: entry)) }
}
