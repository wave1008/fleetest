// CommandsDisplay.swift
// 端末の表示条件(外観・文字サイズ)をシナリオの途中で変える(DR-220〜222)。子は端末へ直接撃たず、`Shell.run` が
// サンドボックスの代行(`DevicectlPolicy` / `AdbPolicy` の display 形)を通す。**戻すのは親の終わりの処理**(`DisplaySettingsEngine.end`)。

import Foundation
import FTCore

extension FTDriveCore {
    /// フックの中で表示条件の変更を断る理由。断らないなら nil。判定は実行中のフェーズ(`currentSection`)で行う =
    /// 補助関数を経由しても止まる。終わりの処理が基準へ戻すので、フックで変えても1本目にしか効かない
    static func displaySettingRejection(command: String, section: String?) -> String? {
        switch section {
        case "beforeAll", "setUpDevice", "tearDownDevice", "afterAll", "beforeRun", "afterRun":
            return "\(command) is not allowed in \(section ?? "")(): the device is returned to the baseline"
                + " (light, default text size) at the end of each scenario, so it would only affect the first test."
                + " To apply it to the whole run, use the run profile's appearance / textSize"
        default:
            return nil
        }
    }

    /// 断るべきなら失敗として記録して true を返す(dry-run でも断る = フック本体は dry-run でも実行される)
    func rejectDisplaySetting(command: String, description: String, file: String, line: Int) -> Bool {
        recordRejection(Self.displaySettingRejection(command: command, section: currentSection),
                        command: command, description: description, file: file, line: line)
    }

    /// 設定して読み返す。期待どおりでなければ投げる(そのステップの失敗)
    func applyDisplaySetting(command: String, key: DisplayKey, expected: String, change: DisplayChange) throws {
        guard let transport = displayTransport() else {
            throw FTCommandError.message("\(command): this device's identifier is not known, so its display settings cannot be changed")
        }
        let budget = DisplayCommandBudget.normal
        let applied = transport.apply(change, budget: budget)
        if let failure = applied.failure { throw FTCommandError.message("\(command): \(failure)") }
        let back = transport.read(budget: budget)
        let actual = back.observation.value(key)
        guard actual == expected else {
            let detail = back.failure.map { " (\($0))" } ?? ""
            throw FTCommandError.message("\(command): expected \(key.rawValue) \(expected), read back \(actual ?? "nothing")\(detail)")
        }
    }

    /// 期待の表示条件を、in-app のアプリが受け取るまで待つ。尽きたら `DriverError.displayNotApplied`(そのステップの失敗)。
    /// **何もしない**: 期待が無い・dry-run・in-app が答えない(xcuitest・Android・旧ブリッジ・通信断)・申告の欄が無い
    func awaitDisplayReachedApp(limitSeconds: TimeInterval = DisplaySettingsLimits.appPropagationSeconds) async throws {
        guard !dryRun, let expected = displayAppExpectation.value else { return }
        let clock = ContinuousClock()
        let start = clock.now
        let limit = limitSeconds
        while true {
            guard let report = await driver.inAppDisplayReport(), !report.isEmpty else { return }
            let mismatches = DisplayAppCheck.mismatches(expected: expected, report: report)
            if mismatches.isEmpty { return }
            let elapsed = DurationConversion.seconds(clock.now - start)
            if elapsed >= limit {
                throw DriverError.displayNotApplied(
                    detail: DisplayAppCheck.failureDetail(mismatches: mismatches, waitedSeconds: limit))
            }
            try await Task.sleep(nanoseconds: UInt64(DisplaySettingsLimits.appPropagationPollSeconds * 1_000_000_000))
        }
    }

    /// DSL で変えた値を以後の確かめの期待にする(確かめる対象でなかった = nil のキーも、変えた時点から確かめる)
    func updateDisplayExpectation(appearance: FTAppearance? = nil, textSize: FTTextSize? = nil) {
        displayAppExpectation.withLock { current in
            var next = current ?? DisplayAppExpectation()
            if let appearance { next.appearance = appearance }
            if let textSize { next.textSize = textSize }
            current = next
        }
    }

    private func displayTransport() -> DisplaySettingsTransport? {
        guard let id = deviceIdentifier, !id.isEmpty else { return nil }
        switch platform {
        case "ios": return IOSDisplaySettingsTransport(udid: id)
        case "android": return AndroidDisplaySettingsTransport(serial: id)
        default: return nil
        }
    }
}

/// 外観を切り替える(`setAppearance(.dark)`)。iOS は Simulator も実機も `devicectl`・Android は `cmd uimode night`。
/// 設定して読み返し、違っていればステップの失敗。**シナリオの終わりに親が基準の状態(light)へ戻す**。
/// beforeRun / afterRun / setUpDevice / tearDownDevice / beforeAll / afterAll の中では使えない。dry-run は何も送らない。
/// Android はアプリの `configChanges` に `uiMode` が無いと画面(Activity)が作り直される
public func setAppearance(_ appearance: FTAppearance,
                          file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "setAppearance")
    let description = "setAppearance .\(appearance.rawValue)"
    if !core.scenarioAborted,
       core.rejectDisplaySetting(command: "setAppearance", description: description, file: "\(file)", line: Int(line)) { return }
    core.performCustom(description: description, command: "setAppearance", file: file, line: line) {
        try core.applyDisplaySetting(command: "setAppearance", key: .appearance, expected: appearance.rawValue,
                                     change: DisplayChange(appearance: appearance))
        core.updateDisplayExpectation(appearance: appearance)
        try await core.awaitDisplayReachedApp()
    }
}

/// 文字サイズを切り替える(`setTextSize(.extraLarge)`)。iOS は `devicectl`(`.accessibility` は「より大きな文字」も有効にする)・
/// Android は `font_scale`。名前の対応は docs/commands.md。それ以外は `setAppearance` と同じ(終わりに `default` へ戻る・フックの中では不可)。
/// Android はアプリの `configChanges` に `fontScale` が無いと画面(Activity)が作り直される
public func setTextSize(_ size: FTTextSize,
                        file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "setTextSize")
    let description = "setTextSize .\(size.rawValue)"
    if !core.scenarioAborted,
       core.rejectDisplaySetting(command: "setTextSize", description: description, file: "\(file)", line: Int(line)) { return }
    core.performCustom(description: description, command: "setTextSize", file: file, line: line) {
        let change = DisplaySettingsPlan.change(keys: [.textSize], target: DisplayExpectation(appearance: nil, textSize: size),
                                                restoreLarger: nil)
        try core.applyDisplaySetting(command: "setTextSize", key: .textSize, expected: size.rawValue, change: change)
        core.updateDisplayExpectation(textSize: size)
        try await core.awaitDisplayReachedApp()
    }
}
