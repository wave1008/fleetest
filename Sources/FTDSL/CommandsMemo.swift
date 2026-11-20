// CommandsMemo.swift
// メモは2種類。名前・挙動は Shirates の Memo と同じ(write は履歴に追記・read は最後の値か ""・clear は全消去)。
//   writeMemo / readMemo / clearMemo / memoTextAs        = テスト1本(beforeEach・本体・afterEach)。シナリオのプロセスの中だけで完結し、親へ通知しない
//   writeRunMemo / readRunMemo / clearRunMemo / runMemoTextAs = run 全体(マシンをまたいで1つ。DR-208)。履歴は親が持ち、
//     シナリオは開始時点の写しを見る。親への通知とハンドオフの契約は FTCore/DeviceSessionHandoff.swift

import Foundation
import FTCore

extension FTDriveCore {
    func testMemoAppend(_ key: String, _ text: String) {
        testMemo[key, default: []].append(text)
    }

    /// 追記する。呼び出し側が scenarioAborted を先に見る。断る・失敗したときは理由(英語)を返す(書いていない or 届いたか不明)。
    /// **ロックの中**(RR-8.5): サーバーへ送って確定の返事を待つ(失敗しても親への片道通知へ落とさない = DR-136)。
    /// **ロックの外**: 手元の写しへ追記して親へ片道通知する(応答なし)
    func runMemoAppend(command: String, _ key: String, _ text: String) -> String? {
        let op = RunMemoOp.write(key: key, value: text)
        if let reason = runLocks.memoWriteRejection(command: command, op: op) { return reason }
        if runLocks.usesServerMemo {
            if let failure = runLocks.serverMemoWrite(op) { return failure.message }
            runMemo[key, default: []].append(text)
            return nil
        }
        runMemo[key, default: []].append(text)
        var event = ScenarioEvent(kind: "runMemoWrite")
        event.memoKey = key
        event.memoValue = text
        runLocks.noteOutsideMemoOp()  // 親が適用し終えるまでロックの中の読み書きは待たされる(RunLockMessage.memoRead)
        emit(event)
        return nil
    }

    func runMemoRemoveAll(command: String) -> String? {
        if let reason = runLocks.memoWriteRejection(command: command, op: .clear) { return reason }
        if runLocks.usesServerMemo {
            if let failure = runLocks.serverMemoWrite(.clear) { return failure.message }
            runMemo.removeAll()
            return nil
        }
        runMemo.removeAll()
        runLocks.noteOutsideMemoOp()
        emit(ScenarioEvent(kind: "runMemoClear"))
        return nil
    }
}

extension FTDriveCore {
    /// test 範囲のメモをテスト関数の外(beforeAll / setUpDevice / tearDownDevice / afterAll)で触るのを断る理由(DR-208)。
    /// 読みも書きも断る。触ってよい場所なら nil。判定は実行中のフェーズ(`currentSection`)で行う = ヘルパー関数を経由しても止まる
    static func testMemoRejection(command: String, section: String?) -> String? {
        switch section {
        case "beforeAll", "setUpDevice", "tearDownDevice", "afterAll", "beforeRun", "afterRun":
            return "\(command) is not allowed in \(section ?? "")(): the memo lives inside one test"
                + " (beforeEach(), the test body and afterEach()). To share a value across the run, use"
                + " writeRunMemo / readRunMemo instead"
        default:
            return nil
        }
    }

    /// setUpDevice / tearDownDevice / afterAll での run メモの書き込みを断る理由(DR-207 を引き継ぐ)。書いてよい場所なら nil。
    /// 読み(readRunMemo)は断らないので呼ばない
    static func runMemoWriteRejection(command: String, section: String?) -> String? {
        switch section {
        case "setUpDevice":
            return "\(command) is not allowed in setUpDevice(): the value would be overwritten by the other devices' values."
                + " Write it in beforeAll() instead"
        case "tearDownDevice", "afterAll":
            return "\(command) is not allowed in \(section ?? "")(): the tests have already finished."
                + " Write it in beforeRun() or in the tests instead"
        case "afterRun":
            return "\(command) is not allowed in afterRun(): the tests have already finished."
                + " Write it in beforeRun() or in the tests instead"
        default:
            return nil
        }
    }

    func recordRejection(_ reason: String?, command: String, description: String,
                                 file: String, line: Int) -> Bool {
        guard let reason else { return false }
        recordStep(description: description, status: .failed(reason), file: file, line: line, command: command)
        handleFailure(stepDescription: description, reason: reason)
        return true
    }

    /// test 範囲のメモの入口(読み・書きとも)がテスト関数の外なら失敗として記録して true を返す
    func rejectTestMemo(command: String, description: String, file: String, line: Int) -> Bool {
        recordRejection(Self.testMemoRejection(command: command, section: currentSection),
                        command: command, description: description, file: file, line: line)
    }

    /// run メモの書き込みを断るべきなら失敗として記録して true を返す(writeRunMemo・runMemoTextAs ×2・clearRunMemo が呼ぶ)
    func rejectRunMemoWrite(command: String, description: String, file: String, line: Int) -> Bool {
        recordRejection(Self.runMemoWriteRejection(command: command, section: currentSection),
                        command: command, description: description, file: file, line: line)
    }

    /// 要素のテキスト(ラベル → 値のうち空でない最初のもの)。要素を掴めていなければ nil
    static func memoText(of element: FTElement) -> String? {
        element.matched.map { m in [m.label, m.value].compactMap { $0 }.first { !$0.isEmpty } ?? "" }
    }
}

// MARK: - test 範囲のメモ

/// テスト1本のメモにキーの値を追記する(履歴を持ち、readMemo は最後の値を返す)
public func writeMemo(_ key: String, _ text: String,
                      file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "writeMemo")
    let description = "writeMemo \"\(key)\" = \"\(text)\""
    core.debugCheckpoint(description: description, file: core.relativePath("\(file)"), line: Int(line))
    if core.scenarioAborted {
        core.recordStep(description: description, status: .skipped(core.skipReason),
                        file: "\(file)", line: Int(line), command: "writeMemo")
        return
    }
    if core.rejectTestMemo(command: "writeMemo", description: description, file: "\(file)", line: Int(line)) { return }
    core.testMemoAppend(key, text)
    core.recordStep(description: description, status: .passed,
                    file: "\(file)", line: Int(line), command: "writeMemo")
}

/// テスト1本のメモのキーの最後の値を返す。**無ければ ""**(失敗にしない。Shirates と同じ)で、注記 `memo-key-not-found` を残す
@discardableResult
public func readMemo(_ key: String,
                     file: StaticString = #filePath, line: UInt = #line) -> String {
    let core = FTRuntime.requireCore(command: "readMemo")
    core.debugCheckpoint(description: "readMemo \"\(key)\"", file: core.relativePath("\(file)"), line: Int(line))
    if core.scenarioAborted {
        core.recordStep(description: "readMemo \"\(key)\"", status: .skipped(core.skipReason),
                        file: "\(file)", line: Int(line), command: "readMemo")
        return ""
    }
    if core.rejectTestMemo(command: "readMemo", description: "readMemo \"\(key)\"", file: "\(file)", line: Int(line)) {
        return ""
    }
    guard let value = core.testMemo[key]?.last else {
        core.recordStep(description: "readMemo \"\(key)\" → \"\"", status: .passed,
                        file: "\(file)", line: Int(line), notes: [.memoKeyNotFound], command: "readMemo")
        return ""
    }
    core.recordStep(description: "readMemo \"\(key)\" → \"\(value)\"", status: .passed,
                    file: "\(file)", line: Int(line), command: "readMemo")
    return value
}

/// テスト1本のメモを全部消す
public func clearMemo(file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "clearMemo")
    core.debugCheckpoint(description: "clearMemo", file: core.relativePath("\(file)"), line: Int(line))
    if core.scenarioAborted {
        core.recordStep(description: "clearMemo", status: .skipped(core.skipReason),
                        file: "\(file)", line: Int(line), command: "clearMemo")
        return
    }
    if core.rejectTestMemo(command: "clearMemo", description: "clearMemo", file: "\(file)", line: Int(line)) { return }
    core.testMemo.removeAll()
    core.recordStep(description: "clearMemo", status: .passed,
                    file: "\(file)", line: Int(line), command: "clearMemo")
}

// MARK: - run メモ

/// run メモにキーの値を追記する(履歴を持ち、readRunMemo は最後の値を返す)。親へ通知する
public func writeRunMemo(_ key: String, _ text: String,
                         file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "writeRunMemo")
    let description = "writeRunMemo \"\(key)\" = \"\(text)\""
    core.debugCheckpoint(description: description, file: core.relativePath("\(file)"), line: Int(line))
    if core.scenarioAborted {
        core.recordStep(description: description, status: .skipped(core.skipReason),
                        file: "\(file)", line: Int(line), command: "writeRunMemo")
        return
    }
    if core.rejectRunMemoWrite(command: "writeRunMemo", description: description, file: "\(file)", line: Int(line)) { return }
    if core.recordRejection(core.runMemoAppend(command: "writeRunMemo", key, text), command: "writeRunMemo",
                            description: description, file: "\(file)", line: Int(line)) { return }
    core.recordStep(description: description, status: .passed,
                    file: "\(file)", line: Int(line), command: "writeRunMemo")
}

/// run メモのキーの最後の値を返す。**無ければ ""**(失敗にしない)で、注記 `run-memo-key-not-found` を残す。
/// 読みはどのフェーズでも可
@discardableResult
public func readRunMemo(_ key: String,
                        file: StaticString = #filePath, line: UInt = #line) -> String {
    let core = FTRuntime.requireCore(command: "readRunMemo")
    core.debugCheckpoint(description: "readRunMemo \"\(key)\"", file: core.relativePath("\(file)"), line: Int(line))
    if core.scenarioAborted {
        core.recordStep(description: "readRunMemo \"\(key)\"", status: .skipped(core.skipReason),
                        file: "\(file)", line: Int(line), command: "readRunMemo")
        return ""
    }
    // ロックの中ならサーバーの最新の値を聞く(ロックを出た後もその写しを見続ける)
    if core.recordRejection(core.refreshRunMemoFromLockServer(), command: "readRunMemo",
                            description: "readRunMemo \"\(key)\"", file: "\(file)", line: Int(line)) { return "" }
    guard let value = core.runMemo[key]?.last else {
        core.recordStep(description: "readRunMemo \"\(key)\" → \"\"", status: .passed,
                        file: "\(file)", line: Int(line), notes: [.runMemoKeyNotFound], command: "readRunMemo")
        return ""
    }
    core.recordStep(description: "readRunMemo \"\(key)\" → \"\(value)\"", status: .passed,
                    file: "\(file)", line: Int(line), command: "readRunMemo")
    return value
}

/// run メモを全部消す(親へ通知する)
public func clearRunMemo(file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "clearRunMemo")
    core.debugCheckpoint(description: "clearRunMemo", file: core.relativePath("\(file)"), line: Int(line))
    if core.scenarioAborted {
        core.recordStep(description: "clearRunMemo", status: .skipped(core.skipReason),
                        file: "\(file)", line: Int(line), command: "clearRunMemo")
        return
    }
    if core.rejectRunMemoWrite(command: "clearRunMemo", description: "clearRunMemo", file: "\(file)", line: Int(line)) { return }
    if core.recordRejection(core.runMemoRemoveAll(command: "clearRunMemo"), command: "clearRunMemo",
                            description: "clearRunMemo", file: "\(file)", line: Int(line)) { return }
    core.recordStep(description: "clearRunMemo", status: .passed,
                    file: "\(file)", line: Int(line), command: "clearRunMemo")
}

// MARK: - memoTextAs / runMemoTextAs

extension FTElement {
    /// 掴んだ要素のテキスト(ラベル → 値のうち**空でない最初のもの**。Shirates の textOrLabel と同じく空文字は
    /// 「無い」扱い = 入力欄はラベルが "" で値に文字を持つ)をテスト1本のメモに書き、要素を返す。
    /// 要素を掴めていない(`isEmpty`)ときは失敗にする(空文字を黙って書かない)。dry-run は "" を書く
    @discardableResult
    public func memoTextAs(_ key: String,
                           file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        memoText(key, command: "memoTextAs", file: file, line: line) { core, value in core.testMemoAppend(key, value); return nil }
    }

    /// `memoTextAs` の run メモ版(親へ通知する。書き込みを断る場所は writeRunMemo と同じ)
    @discardableResult
    public func runMemoTextAs(_ key: String,
                              file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        memoText(key, command: "runMemoTextAs", file: file, line: line) { core, value in core.runMemoAppend(command: "runMemoTextAs", key, value) }
    }

    private func memoText(_ key: String, command: String, file: StaticString, line: UInt,
                          append: (FTDriveCore, String) -> String?) -> FTElement {
        let core = FTRuntime.requireCore(command: command)
        let description = "\(command) \"\(key)\""
        core.debugCheckpoint(description: description, file: core.relativePath("\(file)"), line: Int(line))
        let filePath = "\(file)"
        if core.scenarioAborted {
            core.recordStep(description: description, status: .skipped(core.skipReason),
                            file: filePath, line: Int(line), command: command)
            return self
        }
        let rejected = command == "runMemoTextAs"
            ? core.rejectRunMemoWrite(command: command, description: description, file: filePath, line: Int(line))
            : core.rejectTestMemo(command: command, description: description, file: filePath, line: Int(line))
        if rejected { return self }
        let text = FTDriveCore.memoText(of: self)
        if text == nil && !core.dryRun {
            let reason = "no element to read the text from (the previous select/exist grabbed nothing)"
            core.recordStep(description: description, status: .failed(reason),
                            file: filePath, line: Int(line), command: command)
            core.handleFailure(stepDescription: description, reason: reason)
            return self
        }
        let value = text ?? ""
        if core.recordRejection(append(core, value), command: command, description: description,
                                file: filePath, line: Int(line)) { return self }
        core.recordStep(description: "\(description) = \"\(value)\"", status: .passed,
                        file: filePath, line: Int(line), command: command)
        return self
    }
}

extension String {
    /// 文字列をテスト1本のメモに書き、その文字列を返す(`readText` 等の戻り値をそのまま繋げられる)
    @discardableResult
    public func memoTextAs(_ key: String,
                           file: StaticString = #filePath, line: UInt = #line) -> String {
        memoText(key, command: "memoTextAs", file: file, line: line) { core in core.testMemoAppend(key, self); return nil }
    }

    /// `memoTextAs` の run メモ版(親へ通知する。書き込みを断る場所は writeRunMemo と同じ)
    @discardableResult
    public func runMemoTextAs(_ key: String,
                              file: StaticString = #filePath, line: UInt = #line) -> String {
        memoText(key, command: "runMemoTextAs", file: file, line: line) { core in core.runMemoAppend(command: "runMemoTextAs", key, self) }
    }

    private func memoText(_ key: String, command: String, file: StaticString, line: UInt,
                          append: (FTDriveCore) -> String?) -> String {
        let core = FTRuntime.requireCore(command: command)
        let description = "\(command) \"\(key)\""
        core.debugCheckpoint(description: description, file: core.relativePath("\(file)"), line: Int(line))
        if core.scenarioAborted {
            core.recordStep(description: description, status: .skipped(core.skipReason),
                            file: "\(file)", line: Int(line), command: command)
            return self
        }
        let rejected = command == "runMemoTextAs"
            ? core.rejectRunMemoWrite(command: command, description: description, file: "\(file)", line: Int(line))
            : core.rejectTestMemo(command: command, description: description, file: "\(file)", line: Int(line))
        if rejected { return self }
        if core.recordRejection(append(core), command: command, description: description,
                                file: "\(file)", line: Int(line)) { return self }
        core.recordStep(description: "\(description) = \"\(self)\"", status: .passed,
                        file: "\(file)", line: Int(line), command: command)
        return self
    }
}
