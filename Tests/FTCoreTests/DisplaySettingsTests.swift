// 端末の表示条件(外観・文字サイズ。DR-220〜222)の語彙・判定・コマンド・撃ち直しと遮断・開始時/終わりの処理・宛先の決定。
import FTTestSupport
import XCTest
@testable import FTCore

final class DisplaySettingsTests: XCTestCase {

    // MARK: 語彙・定数

    func testVocabularyTableIsPinned() {
        XCTAssertEqual(FTTextSize.allCases.map(\.rawValue), ["small", "default", "large", "extraLarge", "accessibility"])
        XCTAssertEqual(FTTextSize.allCases.map(\.iosStep),
                       ["small", "large", "extra-large", "extra-extra-extra-large", "accessibility-large"])
        XCTAssertEqual(FTTextSize.allCases.map(\.androidScale), [0.85, 1.0, 1.15, 1.3, 2.0])
        XCTAssertEqual(FTTextSize.allCases.map(\.androidScaleArgument), ["0.85", "1.0", "1.15", "1.3", "2.0"])
        for size in FTTextSize.allCases { XCTAssertEqual(Double(size.androidScaleArgument), size.androidScale) }
        XCTAssertEqual(FTAppearance.allCases.map(\.rawValue), ["light", "dark"])
        XCTAssertNil(FTTextSize.parse("Large"))
        XCTAssertNil(FTAppearance.parse("auto"))
    }

    func testBaselineIsLightAndDefault() {
        let baseline = DisplayExpectation.baseline
        XCTAssertEqual(baseline.appearance, .light)
        XCTAssertEqual(baseline.textSize, .default)
        XCTAssertFalse(baseline.hasSpecifiedKey)
        let dark = DisplayExpectation(appearance: .dark, textSize: nil)
        XCTAssertTrue(dark.appearanceSpecified)
        XCTAssertFalse(dark.textSizeSpecified)
        XCTAssertEqual(dark.summary, "appearance=dark, textSize=default")
    }

    /// 既定値はリテラルで固定する(他のテストが差し替え口で値を明示しても production の既定を通る)。根拠は DR-222
    func testLimitsArePinned() {
        XCTAssertEqual(DisplaySettingsLimits.commandTimeoutSeconds, 10)
        XCTAssertEqual(DisplaySettingsLimits.retryCount, 1)
        XCTAssertEqual(DisplaySettingsLimits.backoffSeconds, 30)
        XCTAssertEqual(DisplaySettingsLimits.interruptedTimeoutSeconds, 5)
        XCTAssertEqual(DisplaySettingsLimits.devicectlMinimumTimeoutSeconds, 5)
        XCTAssertEqual(DisplayCommandBudget.normal, DisplayCommandBudget(timeoutSeconds: 10, retries: 1))
        XCTAssertEqual(DisplayCommandBudget.interrupted, DisplayCommandBudget(timeoutSeconds: 5, retries: 0))
    }

    /// devicectl は `--timeout` が 5 未満だと撃たずに exit 64 で断る(中断の戻しが毎回失敗した)。どの上限も下限を下回らない
    func testEveryBudgetMeetsTheDevicectlMinimum() {
        for budget in [DisplayCommandBudget.normal, .interrupted] {
            XCTAssertGreaterThanOrEqual(budget.timeoutSeconds, DisplaySettingsLimits.devicectlMinimumTimeoutSeconds, "\(budget)")
            let args = DisplaySettingsCommands.iosRead(udid: "U", timeoutSeconds: budget.timeoutSeconds)
            let value = args.firstIndex(of: "--timeout").map { Int(args[$0 + 1]) ?? 0 } ?? 0
            XCTAssertGreaterThanOrEqual(value, DisplaySettingsLimits.devicectlMinimumTimeoutSeconds, "\(args)")
        }
    }

    // MARK: 純粋な判定

    func testKeysToSetOnlyDiffersAndTreatsUnreadAsDifferent() {
        let expected = DisplayExpectation(appearance: .dark, textSize: .large)
        let both: Set<DisplayKey> = [.appearance, .textSize]
        XCTAssertEqual(DisplaySettingsPlan.keysToSet(
            expected: expected, observed: DisplayObservation(appearance: "dark", textSize: "large"), handling: both), [])
        XCTAssertEqual(DisplaySettingsPlan.keysToSet(
            expected: expected, observed: DisplayObservation(appearance: "light", textSize: "large"), handling: both), [.appearance])
        XCTAssertEqual(DisplaySettingsPlan.keysToSet(
            expected: expected, observed: DisplayObservation(appearance: "dark", textSize: nil), handling: both), [.textSize])
        XCTAssertEqual(DisplaySettingsPlan.keysToSet(
            expected: expected, observed: DisplayObservation(), handling: both), both)
        // 扱わないキーは差があっても出さない
        XCTAssertEqual(DisplaySettingsPlan.keysToSet(
            expected: expected, observed: DisplayObservation(appearance: "light", textSize: "small"), handling: [.textSize]), [.textSize])
    }

    func testHandledKeysDropUnspecifiedKeysOnlyWhenBaselineIsUnreachable() {
        let appearanceOnly = DisplayExpectation(appearance: .dark, textSize: nil)
        XCTAssertEqual(DisplaySettingsPlan.handledKeys(expected: appearanceOnly, baselineUnreachable: false), [.appearance, .textSize])
        XCTAssertEqual(DisplaySettingsPlan.handledKeys(expected: appearanceOnly, baselineUnreachable: true), [.appearance])
        XCTAssertEqual(DisplaySettingsPlan.handledKeys(expected: .baseline, baselineUnreachable: true), [])
    }

    func testChangeEnablesLargerSizesForAccessibilityAndRestoresIt() {
        let accessibility = DisplayExpectation(appearance: nil, textSize: .accessibility)
        XCTAssertEqual(DisplaySettingsPlan.change(keys: [.textSize], target: accessibility, restoreLarger: nil),
                       DisplayChange(appearance: nil, textSize: .accessibility, largerAccessibilitySizes: true))
        // 終わり: 基準の文字サイズへ戻すのと同じコマンドで、開始時の「より大きな文字」へ戻す
        XCTAssertEqual(DisplaySettingsPlan.change(keys: [.textSize], target: .baseline, restoreLarger: false),
                       DisplayChange(appearance: nil, textSize: .default, largerAccessibilitySizes: false))
        XCTAssertEqual(DisplaySettingsPlan.change(keys: [.appearance], target: .baseline, restoreLarger: nil),
                       DisplayChange(appearance: .light, textSize: nil, largerAccessibilitySizes: nil))
        XCTAssertTrue(DisplaySettingsPlan.change(keys: [], target: .baseline, restoreLarger: nil).isEmpty)
        XCTAssertFalse(DisplaySettingsPlan.change(keys: [], target: .baseline, restoreLarger: true).isEmpty)
    }

    func testLargerToRestore() {
        XCTAssertNil(DisplaySettingsPlan.largerToRestore(atStart: nil, now: true))
        XCTAssertNil(DisplaySettingsPlan.largerToRestore(atStart: false, now: false))
        XCTAssertEqual(DisplaySettingsPlan.largerToRestore(atStart: false, now: true), false)
        XCTAssertEqual(DisplaySettingsPlan.largerToRestore(atStart: true, now: nil), true)
    }

    func testFailureClassificationFollowsTable34() {
        let expected = DisplayExpectation(appearance: .dark, textSize: nil)
        let verdict = DisplaySettingsPlan.classifyFailures([.appearance, .textSize], expected: expected)
        XCTAssertEqual(verdict.mustFail, [.appearance])
        XCTAssertEqual(verdict.warn, [.textSize])
        let none = DisplaySettingsPlan.classifyFailures([], expected: expected)
        XCTAssertTrue(none.mustFail.isEmpty && none.warn.isEmpty)
        let baseline = DisplaySettingsPlan.classifyFailures([.appearance], expected: .baseline)
        XCTAssertTrue(baseline.mustFail.isEmpty)
        XCTAssertEqual(baseline.warn, [.appearance])
    }

    // MARK: 出力の解析

    /// 実機 SE3(iOS 26.6.2)の `devicectl device info appearance --json-output -` の実際の形(要点だけ)
    private let iosJSON = """
    {"info":{"outcome":"success"},"result":{"largerAccessibilitySizesEnabled":false,"textSize":"Large","userInterfaceStyle":"light"}}
    """

    func testParsesIOSJSON() throws {
        let observation = try XCTUnwrap(DisplaySettingsParser.ios(json: Data(iosJSON.utf8)))
        XCTAssertEqual(observation, DisplayObservation(appearance: "light", textSize: "default", largerAccessibilitySizes: false))
        XCTAssertNil(DisplaySettingsParser.ios(json: Data("not json".utf8)))
        XCTAssertNil(DisplaySettingsParser.ios(json: Data(#"{"info":{}}"#.utf8)))
        let dark = Data(#"{"result":{"textSize":"Extra Extra Extra Large","userInterfaceStyle":"dark"}}"#.utf8)
        XCTAssertEqual(DisplaySettingsParser.ios(json: dark)?.textSize, "extraLarge")
        XCTAssertEqual(DisplaySettingsParser.ios(json: dark)?.appearance, "dark")
        // 語彙に無い段階は生の値(medium は語彙に無い)
        let medium = Data(#"{"result":{"textSize":"Medium","userInterfaceStyle":"light"}}"#.utf8)
        XCTAssertEqual(DisplaySettingsParser.ios(json: medium)?.textSize, "medium")
        let accessibility = Data(#"{"result":{"textSize":"accessibility-large","userInterfaceStyle":"light"}}"#.utf8)
        XCTAssertEqual(DisplaySettingsParser.ios(json: accessibility)?.textSize, "accessibility")
    }

    func testParsesAndroidOutputs() {
        XCTAssertEqual(DisplaySettingsParser.androidNight("Night mode: no\n"), "light")
        XCTAssertEqual(DisplaySettingsParser.androidNight("Night mode: yes"), "dark")
        XCTAssertEqual(DisplaySettingsParser.androidNight("Night mode: auto"), "auto")
        XCTAssertNil(DisplaySettingsParser.androidNight(""))
        XCTAssertNil(DisplaySettingsParser.androidNight("Error: something else"))
        XCTAssertEqual(DisplaySettingsParser.androidFontScale("1.0\n"), "default")
        XCTAssertEqual(DisplaySettingsParser.androidFontScale("null\n"), "default")
        XCTAssertEqual(DisplaySettingsParser.androidFontScale("1.15"), "large")
        XCTAssertEqual(DisplaySettingsParser.androidFontScale("2"), "accessibility")
        XCTAssertEqual(DisplaySettingsParser.androidFontScale("1.5"), "1.5")
        XCTAssertNil(DisplaySettingsParser.androidFontScale("  \n"))
    }

    // MARK: コマンドの形

    func testCommandsAreBuiltInTheSandboxPolicyForm() {
        XCTAssertEqual(DisplaySettingsCommands.iosRead(udid: "U", timeoutSeconds: 10),
                       ["xcrun", "devicectl", "device", "info", "appearance", "--device", "U",
                        "--timeout", "10", "--json-output", "-", "-q"])
        XCTAssertEqual(
            DisplaySettingsCommands.iosSet(
                udid: "U", change: DisplayChange(appearance: .dark, textSize: .accessibility, largerAccessibilitySizes: true),
                timeoutSeconds: 10),
            ["xcrun", "devicectl", "device", "settings", "appearance", "--device", "U", "--timeout", "10", "-q",
             "--mode", "dark", "--text-size", "accessibility-large", "--larger-accessibility-sizes", "on"])
        // 違うキーだけ載せる
        XCTAssertEqual(
            DisplaySettingsCommands.iosSet(udid: "U", change: DisplayChange(appearance: .light), timeoutSeconds: 3),
            ["xcrun", "devicectl", "device", "settings", "appearance", "--device", "U", "--timeout", "3", "-q", "--mode", "light"])
        XCTAssertEqual(DisplaySettingsCommands.androidNightSet(adb: "adb", serial: "S", appearance: .dark),
                       ["adb", "-s", "S", "shell", "cmd", "uimode", "night", "yes"])
        XCTAssertEqual(DisplaySettingsCommands.androidFontScaleSet(adb: "adb", serial: "S", textSize: .large),
                       ["adb", "-s", "S", "shell", "settings", "put", "system", "font_scale", "1.15"])
        XCTAssertEqual(DisplaySettingsCommands.androidNightRead(adb: "adb", serial: "S"),
                       ["adb", "-s", "S", "shell", "cmd", "uimode", "night"])
        XCTAssertEqual(DisplaySettingsCommands.androidFontScaleRead(adb: "adb", serial: "S"),
                       ["adb", "-s", "S", "shell", "settings", "get", "system", "font_scale"])
    }

    // MARK: 撃ち直しと遮断

    private func fakeClock(_ box: LockedValue<ContinuousClock.Instant>) -> @Sendable () -> ContinuousClock.Instant {
        { box.value }
    }

    func testBackoffIsActiveForThirtySecondsAfterATimeout() {
        let base = ContinuousClock.now
        let time = LockedValue<ContinuousClock.Instant>(base)
        let backoff = DisplaySettingsBackoff(now: fakeClock(time))
        XCTAssertFalse(backoff.isActive)
        backoff.noteTimeout()
        XCTAssertTrue(backoff.isActive)
        time.value = base + .seconds(29)
        XCTAssertTrue(backoff.isActive)
        time.value = base + .seconds(30)
        XCTAssertFalse(backoff.isActive)
    }

    func testTimeoutIsRetriedOnceThenFailsAndStartsTheBackoff() {
        let backoff = DisplaySettingsBackoff()
        let calls = LockedValue<Int>(0)
        let transport = IOSDisplaySettingsTransport(udid: "U", backoff: backoff) { _, _ in
            calls.withLock { $0 += 1 }
            throw ShellError.timedOut(args: [], seconds: 15)
        }
        let result = transport.read(budget: .normal)
        XCTAssertEqual(calls.value, 2, "上限を超えたら1回だけ撃ち直す")
        XCTAssertNotNil(result.failure)
        XCTAssertTrue(backoff.isActive)
        // 遮断の間は撃たない
        _ = transport.read(budget: .normal)
        XCTAssertEqual(calls.value, 2)
        let applied = transport.apply(DisplayChange(appearance: .dark), budget: .normal)
        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(applied.failedKeys, [.appearance])
    }

    func testFastFailureIsNotRetriedAndDoesNotStartTheBackoff() {
        let backoff = DisplaySettingsBackoff()
        let calls = LockedValue<Int>(0)
        let transport = IOSDisplaySettingsTransport(udid: "U", backoff: backoff) { _, _ in
            calls.withLock { $0 += 1 }
            return Shell.Result(status: 1, output: "CoreDeviceError 21063")
        }
        let applied = transport.apply(DisplayChange(appearance: .dark, textSize: .large), budget: .normal)
        XCTAssertEqual(calls.value, 1)
        XCTAssertFalse(backoff.isActive, "速く失敗した1台で他の台の設定を止めない")
        XCTAssertEqual(applied.failedKeys, [.appearance, .textSize], "iOS は1コマンドなので両方が失敗")
        XCTAssertTrue(applied.failure?.contains("exit code 1") == true)
        XCTAssertTrue(applied.failure?.contains("21063") == true)
    }

    func testTimeoutJudgmentAndInterruptedBudgetPassTheTimeoutArgument() {
        XCTAssertTrue(DisplayCommandExecutor.isTimeout(status: 1, elapsed: 10.0, limitSeconds: 10))
        XCTAssertFalse(DisplayCommandExecutor.isTimeout(status: 1, elapsed: 0.3, limitSeconds: 10))
        XCTAssertFalse(DisplayCommandExecutor.isTimeout(status: 0, elapsed: 10.0, limitSeconds: 10))
        // 子から撃ったときの代行の時間切れ(すぐ返っても時間切れ)
        XCTAssertTrue(DisplayCommandExecutor.isTimeout(status: SandboxBroker.didNotCompleteStatus, elapsed: 0.1, limitSeconds: 10))
        XCTAssertEqual(FTTextSize.allCases.map(\.androidScaleArgument), ["0.85", "1.0", "1.15", "1.3", "2.0"])
        let seen = LockedValue<[[String]]>([])
        let transport = IOSDisplaySettingsTransport(udid: "U", backoff: DisplaySettingsBackoff()) { args, _ in
            seen.withLock { $0.append(args) }
            return Shell.Result(status: 0, output: #"{"result":{"textSize":"Large","userInterfaceStyle":"light"}}"#)
        }
        XCTAssertNil(transport.read(budget: .interrupted).failure)
        let args = seen.value[0]
        XCTAssertEqual(args.firstIndex(of: "--timeout").map { args[$0 + 1] }, "5",
                       "中断の最中は短い上限(devicectl の下限の 5 秒)を --timeout へ渡す")
    }

    func testAndroidTransportReadsAndSetsPerKey() {
        let seen = LockedValue<[[String]]>([])
        let transport = AndroidDisplaySettingsTransport(serial: "S", adb: "adb") { args, _ in
            seen.withLock { $0.append(args) }
            if args.contains("night"), args.last == "yes" { return Shell.Result(status: 1, output: "boom") }
            if args.contains("night") { return Shell.Result(status: 0, output: "Night mode: no") }
            return Shell.Result(status: 0, output: "null")
        }
        let read = transport.read(budget: .normal)
        XCTAssertEqual(read.observation, DisplayObservation(appearance: "light", textSize: "default"))
        XCTAssertNil(read.failure)
        let applied = transport.apply(DisplayChange(appearance: .dark, textSize: .large), budget: .normal)
        XCTAssertEqual(applied.failedKeys, [.appearance], "Android はキーごとに別のコマンドなので失敗したキーだけ")
        XCTAssertTrue(seen.value.contains(["adb", "-s", "S", "shell", "settings", "put", "system", "font_scale", "1.15"]))
    }

    // MARK: 開始時・終わりの処理(偽の端末)

    private final class FakeDevice: DisplaySettingsTransport, @unchecked Sendable {
        let lock = NSLock()
        var state: DisplayObservation
        var applyFails: Set<DisplayKey> = []
        var readFails = false
        /// true = 遮断中(撃たずに断る)として失敗を返す
        var paused = false
        var applied: [DisplayChange] = []
        var budgets: [DisplayCommandBudget] = []
        var reads = 0
        init(_ state: DisplayObservation) { self.state = state }

        func read(budget: DisplayCommandBudget) -> DisplayReadResult {
            lock.lock(); defer { lock.unlock() }
            reads += 1
            budgets.append(budget)
            if readFails { return DisplayReadResult(observation: DisplayObservation(), failure: "read broke", paused: paused) }
            return DisplayReadResult(observation: state, failure: nil)
        }

        func apply(_ change: DisplayChange, budget: DisplayCommandBudget) -> DisplayApplyResult {
            lock.lock(); defer { lock.unlock() }
            applied.append(change)
            budgets.append(budget)
            let failed = change.keys.intersection(applyFails)
            if !failed.isEmpty { return DisplayApplyResult(failedKeys: failed, failure: "set broke", paused: paused) }
            if let appearance = change.appearance { state.appearance = appearance.rawValue }
            if let textSize = change.textSize { state.textSize = textSize.rawValue }
            if let larger = change.largerAccessibilitySizes { state.largerAccessibilitySizes = larger }
            return .ok
        }
    }

    private func device(_ appearance: String = "light", _ textSize: String = "default", larger: Bool? = nil) -> FakeDevice {
        FakeDevice(DisplayObservation(appearance: appearance, textSize: textSize, largerAccessibilitySizes: larger))
    }

    func testStartDoesNotSetWhenTheDeviceAlreadyMatches() {
        let fake = device()
        let start = DisplaySettingsEngine.start(expected: .baseline, transport: fake, lane: DisplaySettingsLaneState())
        XCTAssertTrue(fake.applied.isEmpty)
        XCTAssertNil(start.failureDetail)
        XCTAssertEqual(start.record, DisplaySettingsRecord(
            expected: .init(appearance: "light", textSize: "default"),
            observed: .init(appearance: "light", textSize: "default"), changed: nil))
        XCTAssertEqual(start.notices.count, 1)
    }

    func testStartSetsOnlyTheDifferingKeysAndReadsBack() {
        let fake = device("dark", "default")
        let expected = DisplayExpectation(appearance: nil, textSize: .large)
        let start = DisplaySettingsEngine.start(expected: expected, transport: fake, lane: DisplaySettingsLaneState())
        // 指定の無い外観(ダークのまま)も基準のライトへ合わせる。違うキーだけ載せる
        XCTAssertEqual(fake.applied, [DisplayChange(appearance: .light, textSize: .large)])
        XCTAssertEqual(fake.reads, 2, "設定の前後で読む")
        XCTAssertNil(start.failureDetail)
        XCTAssertEqual(start.record?.changed, ["appearance", "textSize"])
        XCTAssertEqual(start.record?.observed, .init(appearance: "light", textSize: "large"))
        let onlyText = device("light", "small")
        let second = DisplaySettingsEngine.start(expected: expected, transport: onlyText, lane: DisplaySettingsLaneState())
        XCTAssertEqual(onlyText.applied, [DisplayChange(appearance: nil, textSize: .large)])
        XCTAssertEqual(second.record?.changed, ["textSize"])
    }

    func testStartRemembersLargerAccessibilitySizesAndEndRestoresIt() {
        let fake = device("light", "default", larger: false)
        let expected = DisplayExpectation(appearance: nil, textSize: .accessibility)
        let lane = DisplaySettingsLaneState()
        let start = DisplaySettingsEngine.start(expected: expected, transport: fake, lane: lane)
        XCTAssertEqual(fake.applied, [DisplayChange(appearance: nil, textSize: .accessibility, largerAccessibilitySizes: true)])
        XCTAssertEqual(start.largerAtStart, false)
        fake.applied = []
        let lines = DisplaySettingsEngine.end(started: start, expected: expected, interrupted: false, transport: fake, lane: lane)
        XCTAssertEqual(fake.applied, [DisplayChange(appearance: nil, textSize: .default, largerAccessibilitySizes: false)])
        XCTAssertEqual(fake.state.textSize, "default")
        XCTAssertEqual(fake.state.largerAccessibilitySizes, false)
        XCTAssertEqual(lines.count, 1)
    }

    func testSpecifiedKeyThatCannotBeSetFailsTheScenario() {
        let fake = device()
        fake.applyFails = [.appearance]
        let expected = DisplayExpectation(appearance: .dark, textSize: nil)
        let lane = DisplaySettingsLaneState()
        let start = DisplaySettingsEngine.start(expected: expected, transport: fake, lane: lane)
        XCTAssertNotNil(start.failureDetail)
        XCTAssertTrue(start.failureDetail?.contains("set broke") == true)
        XCTAssertEqual(DisplaySettingsStart.failureSummary(expected),
                       "display settings before the scenario (appearance=dark, textSize=default)")
        XCTAssertNotNil(start.record, "失敗でも期待と読んだ値は結果に残す")
    }

    func testReadBackMismatchOfASpecifiedKeyFails() {
        // 設定は成功と返すが読み返すと違う(反映されていない)
        final class Liar: DisplaySettingsTransport, @unchecked Sendable {
            func read(budget: DisplayCommandBudget) -> DisplayReadResult {
                DisplayReadResult(observation: DisplayObservation(appearance: "light", textSize: "default"), failure: nil)
            }
            func apply(_ change: DisplayChange, budget: DisplayCommandBudget) -> DisplayApplyResult { .ok }
        }
        let start = DisplaySettingsEngine.start(
            expected: DisplayExpectation(appearance: .dark, textSize: nil), transport: Liar(), lane: DisplaySettingsLaneState())
        XCTAssertTrue(start.failureDetail?.contains("expected dark, read back light") == true, "\(String(describing: start.failureDetail))")
    }

    func testUnspecifiedKeyThatCannotBeSetWarnsMarksTheLaneAndIsSkippedUntilASetSucceeds() {
        let fake = device("dark", "default")
        fake.applyFails = [.appearance]
        let lane = DisplaySettingsLaneState()
        let first = DisplaySettingsEngine.start(expected: .baseline, transport: fake, lane: lane)
        XCTAssertNil(first.failureDetail, "指定の無いキーは警告して続ける")
        XCTAssertTrue(first.notices.contains { $0.hasPrefix("⚠️") })
        XCTAssertTrue(lane.baselineUnreachable)
        // 以後は開始時も終わりも何もしない(読みもしない)
        let reads = fake.reads
        let second = DisplaySettingsEngine.start(expected: .baseline, transport: fake, lane: lane)
        XCTAssertTrue(second.didNothing)
        XCTAssertEqual(fake.reads, reads)
        XCTAssertTrue(DisplaySettingsEngine.end(started: second, expected: .baseline, interrupted: false,
                                                transport: fake, lane: lane).isEmpty)
        XCTAssertEqual(fake.reads, reads)
        // 指定のあるシナリオは毎回試みる。設定が1回でも成功したら印は解ける
        fake.applyFails = []
        let specified = DisplaySettingsEngine.start(
            expected: DisplayExpectation(appearance: .light, textSize: nil), transport: fake, lane: lane)
        XCTAssertNil(specified.failureDetail)
        XCTAssertFalse(lane.baselineUnreachable)
    }

    func testEndReturnsToBaselineAndOnlyWarnsOnFailure() {
        let lane = DisplaySettingsLaneState()
        let fake = device("dark", "large")
        let started = DisplaySettingsStart(record: nil, notices: [], failureDetail: nil, changed: [.appearance], largerAtStart: nil)
        let lines = DisplaySettingsEngine.end(started: started, expected: DisplayExpectation(appearance: .dark, textSize: .large),
                                              interrupted: false, transport: fake, lane: lane)
        XCTAssertEqual(fake.state.appearance, "light")
        XCTAssertEqual(fake.state.textSize, "default")
        XCTAssertEqual(lines.count, 1)
        XCTAssertFalse(lines.contains { $0.hasPrefix("⚠️") })

        let stuck = device("dark", "default")
        stuck.applyFails = [.appearance]
        let warned = DisplaySettingsEngine.end(started: started, expected: .baseline, interrupted: false,
                                               transport: stuck, lane: lane)
        XCTAssertTrue(warned.contains { $0.hasPrefix("⚠️") && $0.contains("next scenario") })
    }

    func testEndAlreadyAtBaselineIsSilentButStillReads() {
        let fake = device()
        let started = DisplaySettingsStart(record: nil, notices: [], failureDetail: nil, changed: [], largerAtStart: nil)
        let lines = DisplaySettingsEngine.end(started: started, expected: .baseline, interrupted: false,
                                              transport: fake, lane: DisplaySettingsLaneState())
        XCTAssertTrue(lines.isEmpty)
        XCTAssertEqual(fake.reads, 1, "覚えておいた値に頼らず毎回読む")
        XCTAssertTrue(fake.applied.isEmpty)
    }

    func testEndWhileInterruptedUsesTheShortBudgetOnly() {
        let fake = device("dark", "default")
        let started = DisplaySettingsStart(record: nil, notices: [], failureDetail: nil, changed: [.appearance], largerAtStart: nil)
        _ = DisplaySettingsEngine.end(started: started, expected: .baseline, interrupted: true,
                                      transport: fake, lane: DisplaySettingsLaneState())
        XCTAssertFalse(fake.budgets.isEmpty)
        XCTAssertTrue(fake.budgets.allSatisfy { $0 == .interrupted })
        let normal = device("dark", "default")
        _ = DisplaySettingsEngine.end(started: started, expected: .baseline, interrupted: false,
                                      transport: normal, lane: DisplaySettingsLaneState())
        XCTAssertTrue(normal.budgets.allSatisfy { $0 == .normal })
    }

    func testEndAfterAFailedStartThatChangedNothingDoesNotTouchTheDevice() {
        let fake = device("dark", "default")
        let started = DisplaySettingsStart(record: nil, notices: [], failureDetail: "x", changed: [], largerAtStart: nil)
        XCTAssertTrue(DisplaySettingsEngine.end(started: started, expected: DisplayExpectation(appearance: .dark, textSize: nil),
                                                interrupted: false, transport: fake, lane: DisplaySettingsLaneState()).isEmpty)
        XCTAssertEqual(fake.reads, 0)
    }

    // MARK: 宛先の決定(何もしない経路)

    func testNoTransportForTheNoOpRoutes() {
        let sim = DriverConnection(platform: "ios", udid: "U")
        let phone = DriverConnection(platform: "android", serial: "S")
        XCTAssertNotNil(ScenarioHost.displaySettingsTransport(connection: sim, dryRun: false, lifecycleOnly: false))
        XCTAssertNotNil(ScenarioHost.displaySettingsTransport(connection: phone, dryRun: false, lifecycleOnly: false))
        // dry-run・片付けだけの子
        XCTAssertNil(ScenarioHost.displaySettingsTransport(connection: sim, dryRun: true, lifecycleOnly: false))
        XCTAssertNil(ScenarioHost.displaySettingsTransport(connection: phone, dryRun: true, lifecycleOnly: false))
        XCTAssertNil(ScenarioHost.displaySettingsTransport(connection: sim, dryRun: false, lifecycleOnly: true))
        // 宛先の無い接続(宛先の無い adb は繋がっている別の端末の設定を変える)
        XCTAssertNil(ScenarioHost.displaySettingsTransport(connection: DriverConnection(platform: "ios"), dryRun: false, lifecycleOnly: false))
        XCTAssertNil(ScenarioHost.displaySettingsTransport(connection: DriverConnection(platform: "android"), dryRun: false, lifecycleOnly: false))
        XCTAssertNil(ScenarioHost.displaySettingsTransport(connection: DriverConnection(platform: "android", serial: ""),
                                                          dryRun: false, lifecycleOnly: false))
    }

    // MARK: 配線(型の効かない継ぎ目)

    func testScenarioHostRunsTheDisplaySettingsBeforeTheChildAndAfterItsExit() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let host = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/ScenarioHost.swift"), encoding: .utf8)
        let start = try XCTUnwrap(host.range(of: "DisplaySettingsEngine.start("))
        let launch = try XCTUnwrap(host.range(of: "try process.run()"))
        let finish = try XCTUnwrap(host.range(of: "        finishDisplaySettings()\n", options: .backwards))
        XCTAssertLessThan(start.lowerBound, launch.lowerBound, "子を起こす前に開始時の処理")
        XCTAssertGreaterThan(finish.lowerBound, launch.lowerBound, "子が終わった後に終わりの処理")
        XCTAssertTrue(host.contains("lane: deviceSession.displaySettings"))
    }

    // MARK: プロファイル

    func testProfileKeysFlowToTheExecutionSettings() throws {
        let overrides = try RunProfileSetOverride.parse(["appearance=dark", "textSize=extraLarge"])
        let doc = RunProfileDocument().applyingOverrides(overrides)
        let resolved = DeviceIndependentRunSettings.resolve(doc)
        XCTAssertEqual(resolved.appearance, .dark)
        XCTAssertEqual(resolved.textSize, .extraLarge)
        let settings = ScenarioExecutionSettings(resolved)
        XCTAssertEqual(settings.appearance, .dark)
        XCTAssertEqual(settings.textSize, .extraLarge)
    }

    func testDefaultsAreUnset() {
        XCTAssertNil(ScenarioExecutionSettings().appearance)
        XCTAssertNil(ScenarioExecutionSettings().textSize)
        XCTAssertNil(DeviceIndependentRunSettings.resolve(RunProfileDocument()).appearance)
        XCTAssertNil(DeviceIndependentRunSettings.resolve(DeviceIndependentRunSettings.profileLessBase).textSize)
    }

    func testUnknownValuesAreRejected() {
        XCTAssertThrowsError(try RunProfileSetOverride.parse(["appearance=auto"])) {
            XCTAssertTrue($0.localizedDescription.contains("light/dark"), "\($0)")
        }
        XCTAssertThrowsError(try RunProfileSetOverride.parse(["textSize=huge"])) {
            XCTAssertTrue($0.localizedDescription.contains("extraLarge"), "\($0)")
        }
        let json = #"{"app":"a","devices":[{"platform":"ios","name":"d"}],"appearance":"auto","textSize":"huge"}"#
        let errors = ProfileResolver.validate(kind: .run, data: Data(json.utf8), context: "x").errors
        XCTAssertTrue(errors.contains { $0.contains("appearance") }, "\(errors)")
        XCTAssertTrue(errors.contains { $0.contains("textSize") }, "\(errors)")
    }

    func testRecordRoundTripsAndOmitsTheFieldWhenNothingWasDone() throws {
        let record = ScenarioRunRecord(
            scenarioID: "S0001", platform: "ios", passed: true, startedAt: "2026-11-22T00:00:00Z", durationMs: 1,
            steps: StepCountsRecord(),
            displaySettings: DisplaySettingsRecord(
                expected: .init(appearance: "dark", textSize: "default"),
                observed: .init(appearance: "dark", textSize: "default"), changed: ["appearance"]))
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(ScenarioRunRecord.self, from: data).displaySettings, record.displaySettings)
        let none = try JSONEncoder().encode(ScenarioRunRecord(
            scenarioID: "S0001", platform: "ios", passed: true, startedAt: "x", durationMs: 1, steps: StepCountsRecord()))
        XCTAssertFalse(String(decoding: none, as: UTF8.self).contains("displaySettings"))
    }

    /// 親が「シナリオが表示条件を変えた」と見るコマンド名は DSL の索引の名前と一致する(改名すると終わりの戻しが漏れる = ScenarioHost.run)
    func testWatchedDSLCommandsExistInTheCommandIndex() {
        let names = Set(DSLCommandIndex.all.map(\.name))
        XCTAssertEqual(DisplaySettingsDSL.commands, ["setAppearance", "setTextSize"])
        XCTAssertTrue(DisplaySettingsDSL.commands.isSubset(of: names))
    }

    /// 遮断(プロセス全体)の最中に撃たなかった失敗は、その端末の「合わせられない」印にしない。
    /// 付けると、別の端末の時間切れ1回で、成功する機会の無い端末が run の終わりまで基準へ戻されなくなる
    func testPausedFailureDoesNotMarkTheLaneButItsOwnFailureDoes() {
        let pausedDevice = device("dark", "default")
        pausedDevice.readFails = true
        pausedDevice.applyFails = [.appearance, .textSize]
        pausedDevice.paused = true
        let pausedLane = DisplaySettingsLaneState()
        let pausedStart = DisplaySettingsEngine.start(expected: .baseline, transport: pausedDevice, lane: pausedLane)
        XCTAssertFalse(pausedLane.baselineUnreachable)
        XCTAssertNil(pausedStart.failureDetail)
        XCTAssertTrue(pausedStart.notices.contains { $0.contains("paused") })

        let brokenDevice = device("dark", "default")
        brokenDevice.readFails = true
        brokenDevice.applyFails = [.appearance, .textSize]
        let brokenLane = DisplaySettingsLaneState()
        _ = DisplaySettingsEngine.start(expected: .baseline, transport: brokenDevice, lane: brokenLane)
        XCTAssertTrue(brokenLane.baselineUnreachable)
    }
}
