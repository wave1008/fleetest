// CommandsLock.swift
// run 全体のロック `withRunLock`(RR-8.5・DR-210)。判定・待ち・サーバーとの通信は FTCore の `RunLockScenarioState`
// (`FTDriveCore.runLocks`)。ここは「ステップの記録・失敗の扱い・本体の実行」だけ。
// - 失敗は例外ではなく中断の印: **印が立った後は本体を実行しない**。本体の途中で印が立っても、外すのはブロックを抜けた時点
// - ロックの中の run メモ(読み・書き)の扱いは CommandsMemo.swift

import Foundation
import FTCore

/// 排他ロックを取って本体を実行する。キーは名前の順(UTF-8 のバイト列)に1つずつ取る。取れるまで待つ(上限はこの run の最長の scenarioTimeout・
/// `waitSeconds:` で短くできる)。本体の中の run メモの書き込みはサーバーが確定してから戻る
public func withRunLock(_ keys: String..., waitSeconds: Double? = nil,
                              file: StaticString = #filePath, line: UInt = #line, _ body: () -> Void) {
    FTRuntime.requireCore(command: "withRunLock")
        .runLockBlock(command: "withRunLock", keys: keys, waitSeconds: waitSeconds,
                      file: "\(file)", line: Int(line), body: body)
}

extension FTDriveCore {
    func runLockBlock(command: String, keys: [String], waitSeconds: Double?,
                      file: String, line: Int, body: () -> Void) {
        // 検査の前のキー(制御文字を含みうる)なので、表示用の形にしてから並べる
        let keyText = keys.map { "\"\(RunLockKeys.displayName($0))\"" }.joined(separator: ", ")
        let description = "\(command) \(keyText)"
        debugCheckpoint(description: description, file: relativePath(file), line: line)
        if scenarioAborted {
            recordStep(description: description, status: .skipped(skipReason), file: file, line: line, command: command)
            return
        }
        switch runLocks.enter(keys: keys, waitSeconds: waitSeconds) {
        case .failure(let error):
            recordStep(description: description, status: .failed(error.message), file: file, line: line, command: command)
            handleFailure(stepDescription: description, reason: error.message)
        case .success(let entry):
            // 取った(または dry-run / その場で渡す)。実際に待ったときだけ待った秒を出す
            let waited = entry.waited >= 0.05 ? " (waited \(String(format: "%.1f", entry.waited))s)" : ""
            let sortedKeys = entry.keys.map { "\"\($0)\"" }.joined(separator: ", ")
            // 前の持ち主が接続を失ったキー: 注記(失敗ではない)
            let lost = entry.lostKeys.isEmpty ? "" : " [note: the previous holder of "
                + entry.lostKeys.map { "\"\($0)\"" }.joined(separator: ", ")
                + " lost its connection, so its writes may be missing]"
            recordStep(description: "\(command) \(sortedKeys)\(waited)\(lost)", status: .passed, file: file, line: line, command: command)
            // 本体の途中で失敗の印が立っても、外すのはブロックを抜けたときだけ
            defer { runLocks.leave(entry) }
            body()
        }
    }

    /// ロックの中の `readRunMemo`: サーバーの最新の値へ手元の写しを更新する。失敗したら理由(英語)
    func refreshRunMemoFromLockServer() -> String? {
        guard runLocks.usesServerMemo else { return nil }
        switch runLocks.serverMemoRead() {
        case .success(let values):
            runMemo = values
            return nil
        case .failure(let error): return error.message
        }
    }
}
