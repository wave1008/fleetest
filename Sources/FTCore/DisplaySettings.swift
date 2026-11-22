// DisplaySettings.swift
// 端末の表示条件(外観・文字サイズ)の語彙と、純粋な判定(DR-220・DR-221・DR-222)。
// 端末へ撃つ側は DisplaySettingsDevice.swift・ScenarioHost への組み込みは ScenarioHost+DisplaySettings.swift。
import Foundation

public enum FTAppearance: String, Codable, CaseIterable, Sendable {
    case light, dark

    public static func parse(_ raw: String) -> FTAppearance? { FTAppearance(rawValue: raw) }

    /// `Shell` の引数(`devicectl ... --mode`)
    var iosMode: String { rawValue }
    /// `cmd uimode night` の引数
    var androidNight: String { self == .dark ? "yes" : "no" }

    public static let rule = "must be one of " + allCases.map(\.rawValue).joined(separator: "/")
}

/// 文字サイズ。名前は両 OS の対応表で、本文の文字の大きさの比でそろえる(iOS の本文の標準は 17pt)
public enum FTTextSize: String, Codable, CaseIterable, Sendable {
    case small, `default`, large, extraLarge, accessibility

    public static func parse(_ raw: String) -> FTTextSize? { FTTextSize(rawValue: raw) }

    /// iOS の段階名(`devicectl device settings appearance --text-size`)。`default` = iOS の標準(large)
    var iosStep: String {
        switch self {
        case .small: return "small"
        case .default: return "large"
        case .large: return "extra-large"
        case .extraLarge: return "extra-extra-extra-large"
        case .accessibility: return "accessibility-large"
        }
    }

    /// Android の `font_scale`。Android 14 以降は OS の非線形の拡大で見た目が一致するとは限らない
    var androidScale: Double {
        switch self {
        case .small: return 0.85
        case .default: return 1.0
        case .large: return 1.15
        case .extraLarge: return 1.3
        case .accessibility: return 2.0
        }
    }

    /// `settings put system font_scale` へ渡す文字列(`androidScale` から作る = 0.85 / 1.0 / 1.15 / 1.3 / 2.0。
    /// サンドボックスの許可表 `AdbPolicy.displayCommands` も同じ値から作るので、組み立てと許可がずれない)
    var androidScaleArgument: String { String(androidScale) }

    public static let rule = "must be one of " + allCases.map(\.rawValue).joined(separator: "/")
}

/// 表示条件を変える DSL のコマンド名(`Sources/FTDSL/CommandsDisplay.swift` の `performCustom(command:)` と同じ)。
/// 親はこの名前のステップを見たら、そのシナリオの終わりに必ず基準へ戻す(`ScenarioHost.run`)
public enum DisplaySettingsDSL {
    public static let commands: Set<String> = ["setAppearance", "setTextSize"]
}

public enum DisplayKey: String, CaseIterable, Sendable, Hashable {
    case appearance, textSize
}

/// シナリオの開始時に端末がいるべき状態。指定の無いキーは基準の状態(ライト・標準の文字サイズ)で、
/// 指定の有無は失敗の扱い(DR-221)を分けるので捨てずに持つ
public struct DisplayExpectation: Equatable, Sendable {
    public let appearance: FTAppearance
    public let textSize: FTTextSize
    public let appearanceSpecified: Bool
    public let textSizeSpecified: Bool

    public static let baselineAppearance = FTAppearance.light
    public static let baselineTextSize = FTTextSize.default

    public init(appearance: FTAppearance?, textSize: FTTextSize?) {
        self.appearance = appearance ?? Self.baselineAppearance
        self.textSize = textSize ?? Self.baselineTextSize
        self.appearanceSpecified = appearance != nil
        self.textSizeSpecified = textSize != nil
    }

    public static let baseline = DisplayExpectation(appearance: nil, textSize: nil)

    public var hasSpecifiedKey: Bool { appearanceSpecified || textSizeSpecified }

    public func isSpecified(_ key: DisplayKey) -> Bool {
        key == .appearance ? appearanceSpecified : textSizeSpecified
    }

    /// 期待値の文字列(`FTAppearance.rawValue` / `FTTextSize.rawValue`)
    public func value(_ key: DisplayKey) -> String {
        key == .appearance ? appearance.rawValue : textSize.rawValue
    }

    /// 失敗の説明に使う `appearance=dark, textSize=extraLarge`(指定の無いキーも基準の値で載せる)
    public var summary: String { "appearance=\(appearance.rawValue), textSize=\(textSize.rawValue)" }
}

/// 端末から読んだ値。キーごとに読めなければ nil(nil は「期待と違う」に数える)。
/// 文字列は語彙の名前に写せたときはその名前(`light` / `default` 等)、写せなければ OS の生の値
public struct DisplayObservation: Equatable, Sendable {
    public var appearance: String?
    public var textSize: String?
    /// iOS の「より大きな文字」(Android は nil)
    public var largerAccessibilitySizes: Bool?

    public init(appearance: String? = nil, textSize: String? = nil, largerAccessibilitySizes: Bool? = nil) {
        self.appearance = appearance
        self.textSize = textSize
        self.largerAccessibilitySizes = largerAccessibilitySizes
    }

    public func value(_ key: DisplayKey) -> String? { key == .appearance ? appearance : textSize }
}

/// 1回の設定で端末へ渡す内容。iOS は1コマンド・Android はキーごとに別のコマンド
public struct DisplayChange: Equatable, Sendable {
    public var appearance: FTAppearance?
    public var textSize: FTTextSize?
    /// iOS の「より大きな文字」。nil = 触らない
    public var largerAccessibilitySizes: Bool?

    public init(appearance: FTAppearance? = nil, textSize: FTTextSize? = nil, largerAccessibilitySizes: Bool? = nil) {
        self.appearance = appearance
        self.textSize = textSize
        self.largerAccessibilitySizes = largerAccessibilitySizes
    }

    public var keys: Set<DisplayKey> {
        var result: Set<DisplayKey> = []
        if appearance != nil { result.insert(.appearance) }
        if textSize != nil { result.insert(.textSize) }
        return result
    }

    public var isEmpty: Bool { appearance == nil && textSize == nil && largerAccessibilitySizes == nil }
}

/// 結果の `displaySettings`(docs/results-json.md)。文字列は上の語彙の名前
public struct DisplaySettingsRecord: Codable, Sendable, Equatable {
    public struct Values: Codable, Sendable, Equatable {
        public var appearance: String?
        public var textSize: String?
        public init(appearance: String?, textSize: String?) {
            self.appearance = appearance
            self.textSize = textSize
        }
    }

    /// 期待値(指定の無いキーは基準の値)
    public var expected: Values
    /// 開始時の処理の最後に**読んだ**値(読み返しを含む)。読んでいなければ欄ごと省く
    public var observed: Values?
    /// 開始時に設定したキー(`appearance` / `textSize`)。読んだら既に合っていたキーは入らない。空なら欄ごと省く
    public var changed: [String]?

    public init(expected: Values, observed: Values?, changed: [String]?) {
        self.expected = expected
        self.observed = observed
        self.changed = changed
    }
}

public enum DisplaySettingsPlan {
    /// DR-221 の開始時: 読んだ値と期待の差から、設定すべきキー(`handling` の中だけ)。読めなかったキー(nil)は違うものとして数える
    public static func keysToSet(expected: DisplayExpectation, observed: DisplayObservation,
                                 handling: Set<DisplayKey>) -> Set<DisplayKey> {
        handling.filter { observed.value($0) != expected.value($0) }
    }

    /// DR-221: キーを扱う対象に入れるか。指定のあるキーは常に扱い、指定の無いキーは「合わせられない」端末では扱わない
    /// (毎回の失敗で時間を払わない)
    public static func handledKeys(expected: DisplayExpectation, baselineUnreachable: Bool) -> Set<DisplayKey> {
        Set(DisplayKey.allCases.filter { expected.isSpecified($0) || !baselineUnreachable })
    }

    /// 設定する内容。`target` の値へ `keys` を合わせる。iOS の `accessibility` は「より大きな文字」を同じコマンドで有効にする。
    /// `restoreLarger` = 終わりに開始時の「より大きな文字」へ戻すとき、その値(キーが空でもこれだけで1回の設定になる)
    public static func change(keys: Set<DisplayKey>, target: DisplayExpectation,
                              restoreLarger: Bool?) -> DisplayChange {
        var change = DisplayChange()
        if keys.contains(.appearance) { change.appearance = target.appearance }
        if keys.contains(.textSize) {
            change.textSize = target.textSize
            if target.textSize == .accessibility { change.largerAccessibilitySizes = true }
        }
        if let restoreLarger, change.largerAccessibilitySizes == nil { change.largerAccessibilitySizes = restoreLarger }
        return change
    }

    /// DR-221: 合わせられなかったキーの仕分け。指定のあるキー = そのシナリオを失敗にする・指定の無いキー = 警告して続ける
    public static func classifyFailures(_ failed: Set<DisplayKey>, expected: DisplayExpectation)
        -> (mustFail: [DisplayKey], warn: [DisplayKey]) {
        let ordered = DisplayKey.allCases.filter { failed.contains($0) }
        return (ordered.filter { expected.isSpecified($0) }, ordered.filter { !expected.isSpecified($0) })
    }

    /// 終わりに「より大きな文字」を開始時の値へ戻すか。開始時に読めていて、今の値と違うときだけその値(読めなければ触らない)
    public static func largerToRestore(atStart: Bool?, now: Bool?) -> Bool? {
        guard let atStart, now != atStart else { return nil }
        return atStart
    }

    static func record(expected: DisplayExpectation, observed: DisplayObservation?, changed: [DisplayKey]) -> DisplaySettingsRecord {
        DisplaySettingsRecord(
            expected: .init(appearance: expected.appearance.rawValue, textSize: expected.textSize.rawValue),
            observed: observed.map { .init(appearance: $0.appearance, textSize: $0.textSize) },
            changed: changed.isEmpty ? nil : changed.map(\.rawValue))
    }
}

/// 端末の出力の解析。**終了コード 0 の出力だけを渡す**(`Shell.Result.outputIfSucceeded`)。解析できなければ nil
public enum DisplaySettingsParser {
    /// `devicectl device info appearance --json-output -` の標準出力。
    /// 実測(iOS 26.6.2 の実機): `result.userInterfaceStyle` = `"light"` / `"dark"`・`result.textSize` = `"Large"`・
    /// `result.largerAccessibilitySizesEnabled` = Bool。文字サイズの綴りの揺れ(`Extra Large` / `extra-large` / `ExtraLarge`)は
    /// 文字だけに畳んで段階名と突き合わせる(`result.textSize` が欠けていたら nil)
    public static func ios(json: Data) -> DisplayObservation? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let result = root["result"] as? [String: Any] else { return nil }
        var observation = DisplayObservation()
        if let style = result["userInterfaceStyle"] as? String {
            observation.appearance = style.lowercased()
        }
        if let size = result["textSize"] as? String {
            observation.textSize = iosTextSizeName(size)
        }
        observation.largerAccessibilitySizes = result["largerAccessibilitySizesEnabled"] as? Bool
        return observation
    }

    static func iosTextSizeName(_ raw: String) -> String {
        func letters(_ s: String) -> String { String(s.lowercased().filter(\.isLetter)) }
        let key = letters(raw)
        if let match = FTTextSize.allCases.first(where: { letters($0.iosStep) == key }) { return match.rawValue }
        return raw.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    /// `cmd uimode night` の出力(`Night mode: no`)。`no` = light・`yes` = dark・それ以外(`auto` / `custom_schedule` 等)は生の値
    public static func androidNight(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let lower = line.lowercased()
            guard let range = lower.range(of: "night mode:") else { continue }
            let value = lower[range.upperBound...].trimmingCharacters(in: .whitespaces)
            switch value {
            case "": return nil
            case "no": return FTAppearance.light.rawValue
            case "yes": return FTAppearance.dark.rawValue
            default: return value
            }
        }
        return nil
    }

    /// `settings get system font_scale` の出力。`null`(未設定 = OS の標準 1.0)は `default`。語彙の倍率に写せなければ生の値
    public static func androidFontScale(_ output: String) -> String? {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        if value == "null" { return FTTextSize.default.rawValue }
        guard let scale = Double(value) else { return value }
        if let match = FTTextSize.allCases.first(where: { abs($0.androidScale - scale) < 0.005 }) { return match.rawValue }
        return value
    }
}

/// 端末へ撃つコマンドの組み立て。**引数の並びを変えたらサンドボックスの代行の許可表(`DevicectlPolicy` / `AdbPolicy.displayCommands`)も変える**
/// (DSL の `setAppearance` / `setTextSize` は子から撃つので許可表を通る。`DisplaySettingsSandboxPolicyTests` が突き合わせる)
public enum DisplaySettingsCommands {
    public static func iosRead(udid: String, timeoutSeconds: Int) -> [String] {
        ["xcrun", "devicectl", "device", "info", "appearance", "--device", udid,
         "--timeout", String(timeoutSeconds), "--json-output", "-", "-q"]
    }

    public static func iosSet(udid: String, change: DisplayChange, timeoutSeconds: Int) -> [String] {
        var args = ["xcrun", "devicectl", "device", "settings", "appearance", "--device", udid,
                    "--timeout", String(timeoutSeconds), "-q"]
        if let appearance = change.appearance { args += ["--mode", appearance.iosMode] }
        if let textSize = change.textSize { args += ["--text-size", textSize.iosStep] }
        if let larger = change.largerAccessibilitySizes { args += ["--larger-accessibility-sizes", larger ? "on" : "off"] }
        return args
    }

    public static func androidNightRead(adb: String, serial: String) -> [String] {
        [adb, "-s", serial, "shell", "cmd", "uimode", "night"]
    }

    public static func androidNightSet(adb: String, serial: String, appearance: FTAppearance) -> [String] {
        [adb, "-s", serial, "shell", "cmd", "uimode", "night", appearance.androidNight]
    }

    public static func androidFontScaleRead(adb: String, serial: String) -> [String] {
        [adb, "-s", serial, "shell", "settings", "get", "system", "font_scale"]
    }

    public static func androidFontScaleSet(adb: String, serial: String, textSize: FTTextSize) -> [String] {
        [adb, "-s", serial, "shell", "settings", "put", "system", "font_scale", textSize.androidScaleArgument]
    }
}
