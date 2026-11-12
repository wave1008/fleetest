import XCTest
@testable import FTDSL
@testable import FTCore

/// 利用者の文字列を受け取って比べる・解く経路の**表**(2026-11-09 の調査 35 行の写し)。経路 × 入力の組を等号で固定する。
/// 各経路は production の関数で通す(DSL を dry-run / 値の検証で動かす。DSL から呼べない判定は DSL が呼ぶ FTCore の関数を直に呼ぶ)。
/// **新しい経路を足して表に載せないと落ちる**: `Sources/FTDSL` の公開関数のうち String / Sel を受け取るものをソース走査で全数集め、
/// 表の経路 ID の命令名(`name@variant` の name)+ 許可表(理由つき)と等号で照合する。
/// 期待値は規則(`TextNormalization` / `isBlank` / 正規表現はパターンを書き換えない)から手で導いた。
final class TextInputPathTableTests: XCTestCase {

    enum Outcome: Equatable {
        case refused      // 比べる前に断った(構文・空・誤り)
        case accepted     // 断らなかった(比べる経路ではない)
        case matched
        case notMatched
    }

    static let inputs: [(name: String, value: String)] = [
        ("empty", ""), ("space", " "), ("ideographicSpace", "\u{3000}"), ("newline", "\n"),
        ("invisibleOnly", "\u{200B}"), ("okWithInvisible", "OK\u{200B}"), ("classWithInvisible", "[\u{200B}]"),
        ("emojiVariant", "☺\u{FE0F}"), ("asciiVariant", "a\u{FE0F}"), ("escapedEquals", "\\="),
    ]

    /// 入力の並び順に Outcome を並べる(空・空白・全角空白・改行・見えない文字だけ = 先頭5つは同じ扱いが多いので blank で畳む)
    static func row(blank: Outcome, ok: Outcome, cls: Outcome, smile: Outcome, ascii: Outcome, esc: Outcome) -> [Outcome] {
        Array(repeating: blank, count: 5) + [ok, cls, smile, ascii, esc]
    }

    // MARK: - 実行機

    private final class StubDriver: AppDriver {
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws -> String? { nil }
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                             elements: [], truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private func steps(dryRun: Bool, _ body: @escaping () -> Void) -> [DSLStepRecord] {
        let core = FTDriveCore(driver: StubDriver(), platform: "ios", app: "com.example.app",
                               scenarioID: "T.S0010", scenarioTitle: "t",
                               delegate: nil, healingEnabled: false, tunables: RunTunables(), dryRun: dryRun,
                               fingerprintCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                                   .appendingPathComponent("ft-path-table-\(UUID().uuidString).json"),
                               emit: { _ in })
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        scenario { scene(1, "s") { action { body() } } }
        return core.finalRecord.scenes.flatMap(\.steps)
    }

    private func failureReason(_ steps: [DSLStepRecord]) -> String? {
        for step in steps { if case .failed(let reason) = step.status { return reason } }
        return nil
    }

    /// dry-run で DSL を撃ち、断られたか(失敗) / 通ったか
    private func dslGate(_ body: @escaping () -> Void) -> Outcome {
        failureReason(steps(dryRun: true, body)) == nil ? .accepted : .refused
    }

    /// 値の検証(`this*`)。断り(空)と不一致を文言で分ける(断りの文言は「is empty」を含む)
    private func valueAssert(_ body: @escaping () -> Void) -> Outcome {
        let recorded = steps(dryRun: false, body)
        guard let reason = failureReason(recorded) else { return .matched }
        return reason.contains("is empty") ? .refused : .notMatched
    }

    // MARK: - 比べる実データ

    private static let screenText = "OK\u{200B}"

    private static func element(label: String? = TextInputPathTableTests.screenText, id: String? = nil) -> ElementInfo {
        ElementInfo(ref: 1, type: "staticText", identifier: id, label: label, value: label, placeholder: nil,
                    enabled: true, frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)
    }

    /// 実行機と同じ順の「断る → 比べる」(`emptyExpectationRefusal` → `matchedText` / `negativeAssertSatisfied`)
    private static func assertOutcome(_ assert: String, _ expected: String) -> Outcome {
        if StepExecutor.emptyExpectationRefusal(assert, expected: expected) != nil { return .refused }
        if assert.hasSuffix("Not") || assert.hasSuffix("NotEquals") {
            return LocatorResolver.negativeAssertSatisfied(assert, actual: screenText, expected: expected) ? .matched : .notMatched
        }
        return LocatorResolver.matchedText(screenText, expected: expected, assert: assert) != nil ? .matched : .notMatched
    }

    private static func heldOutcome(_ assert: String, _ expected: String, id: String? = nil,
                                    normalization: TextNormalization = .text) -> Outcome {
        switch HeldElementAssert.satisfied(assert: assert, expected: expected, element: element(id: id),
                                           normalization: normalization) {
        case nil: return .refused
        case true?: return .matched
        case false?: return .notMatched
        }
    }

    // MARK: - 表

    typealias Path = (id: String, expected: [Outcome], run: (String) -> Outcome)

    /// text 系・value 系の検証(正規表現・含む・前方・後方・一致とその否定)。命令名 = DSL の関数名、assert 名 = 実行機の名前
    private static func comparisonPaths() -> [Path] {
        var paths: [Path] = []
        for family in ["text", "value"] {
            let blankRefused = row(blank: .refused, ok: .matched, cls: .notMatched, smile: .notMatched, ascii: .notMatched, esc: .notMatched)
            let blankRefusedNot = row(blank: .refused, ok: .notMatched, cls: .matched, smile: .matched, ascii: .matched, esc: .matched)
            let isRow = row(blank: .notMatched, ok: .matched, cls: .notMatched, smile: .notMatched, ascii: .notMatched, esc: .notMatched)
            let isNotRow = row(blank: .matched, ok: .notMatched, cls: .matched, smile: .matched, ascii: .matched, esc: .matched)
            let matchesRow = row(blank: .refused, ok: .matched, cls: .matched, smile: .notMatched, ascii: .notMatched, esc: .notMatched)
            let matchesNotRow = row(blank: .refused, ok: .notMatched, cls: .notMatched, smile: .matched, ascii: .matched, esc: .matched)
            paths += [
                ("\(family)Is", isRow, { assertOutcome("\(family)Equals", $0) }),
                ("\(family)IsNot", isNotRow, { assertOutcome("\(family)NotEquals", $0) }),
            ]
            for kind in ["Contains", "StartsWith", "EndsWith"] {
                paths.append(("\(family)\(kind)", blankRefused, { assertOutcome("\(family)\(kind)", $0) }))
                paths.append(("\(family)\(kind)Not", blankRefusedNot, { assertOutcome("\(family)\(kind)Not", $0) }))
            }
            paths.append(("\(family)Matches", matchesRow, { assertOutcome("\(family)Matches", $0) }))
            paths.append(("\(family)MatchesNot", matchesNotRow, { assertOutcome("\(family)MatchesNot", $0) }))
        }
        return paths
    }

    private func allPaths() -> [Path] {
        var paths = Self.comparisonPaths()
        let selectorGate = Self.row(blank: .refused, ok: .accepted, cls: .refused, smile: .accepted, ascii: .accepted, esc: .accepted)
        let plainGate = Self.row(blank: .refused, ok: .accepted, cls: .accepted, smile: .accepted, ascii: .accepted, esc: .accepted)
        let typeGate: [Outcome] = [.refused] + Array(repeating: .accepted, count: 9)

        // 文字列セレクタ(perform → FTSelector.preflightError)
        paths += [
            ("exist", selectorGate, { v in self.dslGate { exist(v) } }),
            ("notExist", selectorGate, { v in self.dslGate { notExist(v) } }),
            ("tap", selectorGate, { v in self.dslGate { tap(v) } }),
            ("select", selectorGate, { v in self.dslGate { select(v) } }),
            ("scrollTo", selectorGate, { v in self.dslGate { scrollTo(v) } }),
            // scrollFrame: は検査を通さず空ラベルの要素に当たっていた
            ("scrollDown@scrollFrame", selectorGate, { v in self.dslGate { scrollDown(scrollFrame: v) } }),
            // 宣言の誤りは宣言の時点で落とす
            ("irregularHandler@detect", selectorGate, { v in self.dslGate { irregularHandler(v) } }),
            ("irregularHandler@dismiss", selectorGate, { v in self.dslGate { irregularHandler("#a", dismiss: v) } }),
            ("swipeElementToElement@to", selectorGate, { v in self.dslGate { swipeElementToElement("#a", v) } }),
            // 題名・ボタン名のパターン(`||` と `*`)。空の分岐と見えない文字だけの分岐を断る
            ("iosAlertHandler@alert", plainGate, { v in self.dslGate { iosAlertHandler(alert: v, button: "OK") } }),
            ("iosAlertHandler@button", plainGate, { v in self.dslGate { iosAlertHandler(alert: "*x*", button: v) } }),
            // 入力する文字列: 空文字は replace 無しだと何も起きないので断る。空白だけは入力として正しい
            ("type@text", typeGate, { v in self.dslGate { type(v) } }),
            ("type@selector", typeGate, { v in self.dslGate { type("#a", v) } }),
        ]

        // 型付きセレクタ(Sel)
        paths += [
            ("text@Sel", plainGate, { v in self.dslGate { exist(Sel.text(v)) } }),
            ("text@SelMatches", plainGate, { v in self.dslGate { exist(Sel.text(v, .matches)) } }),
            ("id@Sel", plainGate, { v in self.dslGate { exist(Sel.id(v)) } }),
            ("value@Sel", plainGate, { v in self.dslGate { exist(Sel.value(v)) } }),
            ("placeholder@Sel", plainGate, { v in self.dslGate { exist(Sel.placeholder(v)) } }),
            ("not@Sel", plainGate, { v in self.dslGate { exist(Sel.id("a").not(Sel.text(v))) } }),
        ]

        // 値の検証 this*(実際の値 "OK\u{200B}")
        let thisContainsRow = Self.row(blank: .refused, ok: .matched, cls: .notMatched, smile: .notMatched, ascii: .notMatched, esc: .notMatched)
        let thisContainsNotRow = Self.row(blank: .refused, ok: .notMatched, cls: .matched, smile: .matched, ascii: .matched, esc: .matched)
        let actual = Self.screenText
        paths += [
            ("thisIs", Self.row(blank: .notMatched, ok: .matched, cls: .notMatched, smile: .notMatched, ascii: .notMatched, esc: .notMatched),
             { v in self.valueAssert { actual.thisIs(v) } }),
            ("thisIsNot", Self.row(blank: .matched, ok: .notMatched, cls: .matched, smile: .matched, ascii: .matched, esc: .matched),
             { v in self.valueAssert { actual.thisIsNot(v) } }),
            ("thisContains", thisContainsRow, { v in self.valueAssert { actual.thisContains(v) } }),
            ("thisContainsNot", thisContainsNotRow, { v in self.valueAssert { actual.thisContainsNot(v) } }),
            ("thisStartsWith", thisContainsRow, { v in self.valueAssert { actual.thisStartsWith(v) } }),
            ("thisStartsWithNot", thisContainsNotRow, { v in self.valueAssert { actual.thisStartsWithNot(v) } }),
            ("thisEndsWith", thisContainsRow, { v in self.valueAssert { actual.thisEndsWith(v) } }),
            ("thisEndsWithNot", thisContainsNotRow, { v in self.valueAssert { actual.thisEndsWithNot(v) } }),
            // 正規表現はパターンを書き換えず、素の値と正規化した値の両方に当てる(`[\u{200B}]` は素の値に当たる)
            ("thisMatches", Self.row(blank: .refused, ok: .matched, cls: .matched, smile: .notMatched, ascii: .notMatched, esc: .notMatched),
             { v in self.valueAssert { actual.thisMatches(v) } }),
            ("thisMatchesNot", Self.row(blank: .refused, ok: .notMatched, cls: .notMatched, smile: .matched, ascii: .matched, esc: .matched),
             { v in self.valueAssert { actual.thisMatchesNot(v) } }),
        ]

        // 掴んだ値の高速経路(nil = 高速経路は決めず executor へ落とす = 断りは executor が出す)
        paths += [
            ("textIs@held", Self.row(blank: .notMatched, ok: .matched, cls: .notMatched, smile: .notMatched, ascii: .notMatched, esc: .notMatched),
             { Self.heldOutcome("textEquals", $0) }),
            // strict は一切正規化しない: 素の "OK\u{200B}" だけが一致する
            ("textIs@heldStrict", Self.row(blank: .notMatched, ok: .matched, cls: .notMatched, smile: .notMatched, ascii: .notMatched, esc: .notMatched),
             { Self.heldOutcome("textEquals", $0, normalization: .strict) }),
            ("textContains@held", Self.row(blank: .refused, ok: .matched, cls: .notMatched, smile: .notMatched, ascii: .notMatched, esc: .notMatched),
             { Self.heldOutcome("textContains", $0) }),
            ("textContainsNot@held", Self.row(blank: .refused, ok: .notMatched, cls: .matched, smile: .matched, ascii: .matched, esc: .matched),
             { Self.heldOutcome("textContainsNot", $0) }),
            ("textMatches@held", Self.row(blank: .refused, ok: .matched, cls: .matched, smile: .notMatched, ascii: .notMatched, esc: .notMatched),
             { Self.heldOutcome("textMatches", $0) }),
            ("idIs@held", Self.row(blank: .notMatched, ok: .matched, cls: .notMatched, smile: .notMatched, ascii: .notMatched, esc: .notMatched),
             { Self.heldOutcome("idEquals", $0, id: Self.screenText) }),
            ("idIs", Self.row(blank: .notMatched, ok: .matched, cls: .notMatched, smile: .notMatched, ascii: .notMatched, esc: .notMatched),
             { v in LocatorResolver.matchedText(Self.screenText, expected: v, assert: "idEquals") != nil ? .matched : .notMatched }),
        ]

        // FTCore の判定(DSL が呼ぶ関数を直に)
        paths += [
            ("selector@validationError", selectorGate, { FTSelector.validationError($0) == nil ? .accepted : .refused }),
            ("scrollFrame@locator", selectorGate, { FTSelector.scrollFrameLocator($0).error == nil ? .accepted : .refused }),
            ("selectorLikeInput@guard", Array(repeating: .accepted, count: 10),
             { FTSelector.selectorLikeInputError($0) == nil ? .accepted : .refused }),
            // セレクタの一致(.selector)は空の期待値を全モードで何にも一致させない
            ("flowMatch@exact", Self.row(blank: .notMatched, ok: .matched, cls: .notMatched, smile: .notMatched, ascii: .notMatched, esc: .notMatched),
             { FlowMatchMode.exact.matches("OK", $0) ? .matched : .notMatched }),
            ("flowMatch@startsWith", Self.row(blank: .notMatched, ok: .matched, cls: .notMatched, smile: .notMatched, ascii: .notMatched, esc: .notMatched),
             { FlowMatchMode.startsWith.matches("OK", $0) ? .matched : .notMatched }),
            ("flowMatch@endsWith", Self.row(blank: .notMatched, ok: .matched, cls: .notMatched, smile: .notMatched, ascii: .notMatched, esc: .notMatched),
             { FlowMatchMode.endsWith.matches("OK", $0) ? .matched : .notMatched }),
            ("flowMatch@contains", Self.row(blank: .notMatched, ok: .matched, cls: .notMatched, smile: .notMatched, ascii: .notMatched, esc: .notMatched),
             { FlowMatchMode.contains.matches("OK", $0) ? .matched : .notMatched }),
            // テキストの比較(.text)は空の期待値を「空のテキスト」に一致させる(textIs("") の意味)。空白類は別物
            ("flowMatch@textExactEmptyActual", [.matched, .notMatched, .notMatched, .notMatched, .matched,
                                              .notMatched, .notMatched, .notMatched, .notMatched, .notMatched],
             { FlowMatchMode.exact.matches("", $0, normalization: .text) ? .matched : .notMatched }),
            // 空のパターンは NSRegularExpression が組めず一致なし(DSL は比べる前に断る = textMatches の行)
            ("regex@text", [.notMatched, .notMatched, .notMatched, .notMatched, .matched,
                            .matched, .matched, .notMatched, .notMatched, .notMatched],
             { TextNormalization.regexMatch(Self.screenText, pattern: $0, under: .text) != nil ? .matched : .notMatched }),
            ("alertPattern@declaration", plainGate,
             { SystemAlertDismissal.patternError($0, argument: "alert") == nil ? .accepted : .refused }),
            ("linkText@locator", Array(repeating: .notMatched, count: 5) + [.matched, .notMatched, .notMatched, .notMatched, .notMatched],
             { LinkTextLocator.range(of: $0, in: Self.screenText) != nil ? .matched : .notMatched }),
            ("transcript@normalize", Array(repeating: .notMatched, count: 5) + [.matched, .notMatched, .notMatched, .notMatched, .notMatched],
             { TranscriptMatch.normalize($0) == TranscriptMatch.normalize("OK") ? .matched : .notMatched }),
            ("fingerprint@isIdentifying", Self.row(blank: .refused, ok: .accepted, cls: .accepted, smile: .accepted, ascii: .accepted, esc: .accepted),
             { LocatorFingerprint(type: "button", label: $0, placeholder: nil).isIdentifying ? .accepted : .refused }),
            ("fingerprint@resolve", Array(repeating: .refused, count: 5) + [.matched, .notMatched, .notMatched, .notMatched, .notMatched],
             { v in
                 let fp = LocatorFingerprint(type: "staticText", label: v, placeholder: nil)
                 guard fp.isIdentifying else { return .refused }
                 return fp.resolve(in: [Self.element()]) != nil ? .matched : .notMatched
             }),
            ("argumentBounds@emptyViolation", Self.row(blank: .refused, ok: .accepted, cls: .accepted, smile: .accepted, ascii: .accepted, esc: .accepted),
             { ArgumentBounds.emptyViolation("alertButton", $0) == nil ? .accepted : .refused }),
        ]
        return paths
    }

    func testEveryPathAgreesWithTheTableForEveryInput() {
        var failures: [String] = []
        for path in allPaths() {
            let expected = path.expected
            XCTAssertEqual(expected.count, Self.inputs.count, path.id)
            for (index, input) in Self.inputs.enumerated() where index < expected.count {
                let got = path.run(input.value)
                if got != expected[index] { failures.append("\(path.id) × \(input.name): expected \(expected[index]) got \(got)") }
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    // MARK: - 表に載せない経路を落とす走査

    /// 表に載せない公開関数と理由(許可表)。**理由が書けない関数は表に載せる**
    static let notInTable: [String: String] = {
        var table: [String: String] = [:]
        func add(_ names: [String], _ reason: String) { for name in names { table[name] = reason } }
        add(["clearInput", "doubleTap", "hold", "pinchIn", "pinchOut", "swipeBy", "gesture", "countIs", "waitForDisplay",
             "waitForClose", "waitForSettle", "ifCanSelect", "repeatWhileCanSelect"],
            "selector argument goes through the shared perform(_:_:step:) → FTSelector.preflightError (same gate as exist)")
        add(["flickBottomToTop", "flickCenterToBottom", "flickCenterToLeft", "flickCenterToRight", "flickCenterToTop",
             "flickLeftToRight", "flickRightToLeft", "flickTopToBottom", "scrollLeft", "scrollRight", "scrollUp",
             "scrollToBottom", "scrollToLeftEdge", "scrollToRightEdge", "scrollToTop",
             "withScrollDown", "withScrollLeft", "withScrollRight", "withScrollUp"],
            "scrollFrame: goes through resolvedScrollFrame → FTSelector.scrollFrameLocator (same gate as scrollDown@scrollFrame)")
        add(["or", "find", "right", "left", "above", "below"], "Sel composition: inherits invalidReason from its operands (same gate as text@Sel)")
        add(["setPickerValue"], "selector goes through the shared perform gate; the value is compared with the wheel's text by PickerValueMatch (its own table: PickerValueMatchTests)")
        add(["scene", "group", "verify", "procedure", "doUntilTrue"], "block title / label, never compared")
        add(["launchApp", "openURL", "restartApp", "clearAppData", "installApp", "removeApp", "appIs", "tapAppIcon"],
            "app identifier / URL / name, not a compared text")
        add(["screenshot"], "file name")
        add(["account", "data", "dataFile", "addMedia", "httpRequest"], "dataset / HTTP / media arguments, not compared text")
        add(["memoTextAs", "readMemo", "writeMemo"], "memo keys")
        add(["effectivePlatform", "renderCollapseCheckpoint"], "platform / checkpoint label")
        add(["findImage", "findImages", "existImage", "imageIs"], "image name, matched against the vision classifier labels")
        add(["screenLooksLike"], "text goes to FM; the blank guard (isBlank) lives in StepExecutor.executeAssertScreenMatches and needs the executor")
        add(["textMatchesDateFormat", "valueMatchesDateFormat", "thisMatchesDateFormat"],
            "date format string, not text (intended difference: no normalization)")
        return table
    }()

    /// `Sources/FTDSL` の公開関数(String / Sel を受け取るもの)+ `this*`(String / Any? の期待値)
    static func scannedCommands() throws -> Set<String> {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTDSL")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "UnavailableCommands.swift" }
        XCTAssertFalse(files.isEmpty, "the scan does not reach Sources/FTDSL")
        let publicFunc = try NSRegularExpression(pattern: #"public func (\w+)\(([^{]*?)\)\s*(?:->[^{]*)?\{"#)
        let thisFunc = try NSRegularExpression(pattern: #"\n\s+func (this\w+)\(([^{]*?)\)\s*(?:->[^{]*)?\{"#)
        let textParam = try NSRegularExpression(pattern: #":\s*(String|Sel)\b"#)
        let anyParam = try NSRegularExpression(pattern: #":\s*Any\?"#)
        var found: Set<String> = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in publicFunc.matches(in: source, range: range) {
                guard let name = Range(match.range(at: 1), in: source), let params = Range(match.range(at: 2), in: source) else { continue }
                let p = String(source[params])
                if textParam.firstMatch(in: p, range: NSRange(p.startIndex..., in: p)) != nil { found.insert(String(source[name])) }
            }
            guard file.lastPathComponent == "ValueAssertions.swift" else { continue }
            for match in thisFunc.matches(in: source, range: range) {
                guard let name = Range(match.range(at: 1), in: source), let params = Range(match.range(at: 2), in: source) else { continue }
                let p = String(source[params])
                let whole = NSRange(p.startIndex..., in: p)
                if textParam.firstMatch(in: p, range: whole) != nil || anyParam.firstMatch(in: p, range: whole) != nil {
                    found.insert(String(source[name]))
                }
            }
        }
        return found
    }

    func testEveryTextTakingPublicFunctionIsInTheTableOrTheAllowList() throws {
        let scanned = try Self.scannedCommands()
        let tableCommands = Set(allPaths().map { String($0.id.split(separator: "@", maxSplits: 1)[0]) })
        let allowed = Set(Self.notInTable.keys)
        XCTAssertTrue(tableCommands.isDisjoint(with: allowed), "in both: \(tableCommands.intersection(allowed).sorted())")
        let uncovered = scanned.subtracting(tableCommands).subtracting(allowed)
        XCTAssertTrue(uncovered.isEmpty,
                      "public functions taking text are in neither the path table nor the allow list (add a path, or an allow-list entry with a reason): \(uncovered.sorted())")
        // 表・許可表の側に実在しない名前が残っていないこと(等号)。table の `fingerprint` 等 FTCore 直呼びの経路は DSL の関数名ではない
        let coreDirect: Set<String> = ["selector", "scrollFrame", "selectorLikeInput", "flowMatch", "regex", "alertPattern", "linkText",
                                       "transcript", "fingerprint", "argumentBounds", "idIs"]
        let stale = tableCommands.union(allowed).subtracting(scanned).subtracting(coreDirect)
        XCTAssertTrue(stale.isEmpty, "path table / allow list names a function that no longer exists: \(stale.sorted())")
    }
}
