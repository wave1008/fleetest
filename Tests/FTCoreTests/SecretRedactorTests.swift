// account() の値の伏せ字化。最小長・JSON エスケープ形・長い値の優先・ConsoleOut の最後の網。

import XCTest
@testable import FTCore

final class SecretRedactorTests: XCTestCase {

    func testRegisteredValueIsMasked() {
        let redactor = SecretRedactor()
        redactor.register("p@ssw0rd")
        XCTAssertEqual(redactor.redact("type \"p@ssw0rd\" into #pw"), "type \"***\" into #pw")
        XCTAssertEqual(redactor.redact("nothing here"), "nothing here")
    }

    /// 4 文字未満は登録しない(無関係な文字列を壊す)。境界の 3 / 4 文字で確かめる
    func testShortValuesAreNotRegistered() {
        let redactor = SecretRedactor()
        redactor.register(["abc", "", "ab"])
        XCTAssertEqual(redactor.redact("abc ab is fine"), "abc ab is fine")
        redactor.register("abcd")
        XCTAssertEqual(redactor.redact("xabcdx"), "x***x")
        XCTAssertEqual(SecretRedactor.minimumLength, 4)
    }

    /// NDJSON の行では引用符・バックスラッシュが `\"` `\\` になる。両方の形で伏せる
    func testJSONEscapedFormIsMaskedInAJSONLine() throws {
        let secret = #"pa"ss\word"#
        let redactor = SecretRedactor()
        redactor.register(secret)
        var event = ScenarioEvent(kind: "step")
        event.description = "type \(secret)"
        let line = event.encodedLine()
        XCTAssertFalse(line.contains(secret), "前提: エンコード後は生の形では現れない")
        XCTAssertTrue(line.contains(#"pa\"ss\\word"#), line)
        let masked = redactor.redact(line)
        XCTAssertFalse(masked.contains(#"pa\"ss\\word"#), masked)
        XCTAssertNotNil(ScenarioEvent.decode(line: masked), "伏せた後も有効な JSON の1行")
        XCTAssertEqual(ScenarioEvent.decode(line: masked)?.description, "type ***")
    }

    /// ある値が別の値の一部でも、長い値を先に伏せて断片を残さない
    func testLongerValueIsMaskedBeforeItsSubstring() {
        let redactor = SecretRedactor()
        redactor.register("pass")
        redactor.register("password123")
        XCTAssertEqual(redactor.redact("password123"), "***")
    }

    func testStatusReasonsAreMappedAndOthersKept() {
        let status = StepResult.Status.failed("bad secretvalue")
        guard case .failed(let reason) = status.mappingReasons({ $0.replacingOccurrences(of: "secretvalue", with: "***") })
        else { return XCTFail() }
        XCTAssertEqual(reason, "bad ***")
        guard case .passed = StepResult.Status.passed.mappingReasons({ _ in "x" }) else { return XCTFail() }
    }

    /// 子の標準出力・標準エラーへの文字列の出力は全部 ConsoleOut を通る = 最後の網
    func testConsoleOutMasksRegisteredValues() throws {
        SecretRedactor.shared.register("console-secret")
        defer { SecretRedactor.shared.removeAll() }
        let pipe = Pipe()
        ConsoleOut.emit("line with console-secret inside", fd: pipe.fileHandleForWriting.fileDescriptor)
        try pipe.fileHandleForWriting.close()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(text, "line with *** inside\n")
    }

    // MARK: - 子から親への知らせ(子の print() の行は子の登録簿を通らない)

    /// 知らせの行は親で横取りされ(nil = どこにも書き出さない)、その後の子の行は親の登録簿で伏せられる
    func testHostSwallowsTheAnnouncementAndMasksLaterChildLines() throws {
        let host = SecretRedactor()
        let announcement = try XCTUnwrap(SecretRedactor.hostAnnouncementLine(["hunter2-secret"]))
        XCTAssertTrue(announcement.contains("hunter2-secret"), "知らせの行は値を平文で運ぶ(伏せると親が受け取れない)")
        XCTAssertNil(SecretRedactor.hostStdoutLine(announcement, redactor: host), "知らせは記録にも取り込みにも渡さない")
        XCTAssertEqual(SecretRedactor.hostStdoutLine("printed: hunter2-secret", redactor: host), "printed: ***")
    }

    /// 知らせでない JSON の行・素の行は、登録が無ければそのまま
    func testOtherLinesPassThroughUntouched() {
        let host = SecretRedactor()
        let event = ScenarioEvent(kind: "log").encodedLine()
        XCTAssertEqual(SecretRedactor.hostStdoutLine(event, redactor: host), event)
        XCTAssertEqual(SecretRedactor.hostStdoutLine("plain line", redactor: host), "plain line")
    }

    /// 配線: 子は account の値を知らせつきで登録し、親は stdout の取り込みの先頭(生の記録より前)で処理する
    func testChildAnnouncesAndHostProcessesBeforeRecording() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dataset = try String(contentsOf: root.appendingPathComponent("Sources/FTDSL/CommandsDataset.swift"), encoding: .utf8)
        XCTAssertTrue(dataset.contains("SecretRedactor.shared.registerAndAnnounceToHost("))
        let host = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/ScenarioHost.swift"), encoding: .utf8)
        let intercept = try XCTUnwrap(host.range(of: "guard let line = SecretRedactor.hostStdoutLine(rawLine) else { continue }"))
        let record = try XCTUnwrap(host.range(of: "eventLog?.appendStdout(line)"))
        XCTAssertLessThan(intercept.lowerBound, record.lowerBound, "生の行の記録より前に伏せる")
    }
}
