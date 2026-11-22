// VariantCapture.swift
// `ft_capture_element` の `variant`(DR-225 の画像の側)。端末をそのバリアントの表示条件にして撮り、探索の開始時の値へ戻す。
// 純粋な判定(引数の検査・保存名)と、`DisplaySettingsTransport` だけに依る表示条件の出し入れ。画面の静止の待ち(ブリッジの waitForSettle)と切り出しは呼び手(MCP)。
import Foundation

public enum VariantCapture {
    /// 入口の検査。nil = 通す(`variant` を渡していない呼び出しも nil)
    public static func refusal(variant: String?, selector: String?, ref: Int?, name: String?, profile: String?) -> String? {
        guard let variant else { return nil }
        if ref != nil { return "variant cannot be combined with ref: the tree is re-read after the display settings change, so name the element with selector" }
        if selector == nil { return "variant requires selector (the element is found again after the display settings change)" }
        if name != nil { return "variant cannot be combined with name: the file is named <date>\(FindImage.variantFileMarker(variant)).png" }
        if profile == nil { return "variant needs profile (the run profile that declares the variant)" }
        return nil
    }

    /// 宣言から名前で引く。向きを書いたバリアント・知らない名前・保存名を壊す文字は断る(段3は外観と文字サイズだけ)
    public static func resolve(name: String, profile: String, declared: [ResolvedVariant]) throws -> ResolvedVariant {
        guard !declared.isEmpty else { throw VariantCaptureError("profile \(profile) declares no variants") }
        guard let found = declared.first(where: { $0.name == name }) else {
            throw VariantCaptureError("unknown variant \"\(name)\" (available: \(declared.map(\.name).joined(separator: ", ")))")
        }
        if found.orientation != nil {
            throw VariantCaptureError("variant \"\(name)\" sets orientation, which ft_capture_element does not change"
                + " (only appearance and textSize); rotate the device yourself and capture without variant")
        }
        if name.contains("@") || name.contains("/") {
            throw VariantCaptureError("variant \"\(name)\": a name with \"@\" or \"/\" cannot be part of a template file name")
        }
        return found
    }

    /// 保存名 `<日時>-variant-<name>.png`。OS の印(`@a` / `@i`)を含めない(`FindImage.templateFiles` の判定と取り違えない)
    public static func fileName(variant: String, now: Date = Date()) -> String {
        VisionSample.timestamp(now) + FindImage.variantFileMarker(variant) + ".png"
    }

    /// 連続する2枚の木が同じ形か(静止)。署名は `StepExecutor.settledSignature` と同じ「型 + 枠の左上」
    public static func signature(_ elements: [ElementInfo]) -> String {
        elements.map { "\($0.type)|\($0.frame.x),\($0.frame.y)" }.joined(separator: ",")
    }
}

public struct VariantCaptureError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// 探索の開始時の値を控え、バリアントの値へ設定し、終わりに控えへ戻す。**戻せなかったことは文面で返す**(投げない = 保存の結果を隠さない)
public struct VariantDisplaySession {
    private let transport: DisplaySettingsTransport
    private let variant: ResolvedVariant
    private(set) var start = DisplayObservation()

    public init(transport: DisplaySettingsTransport, variant: ResolvedVariant) {
        self.transport = transport
        self.variant = variant
    }

    /// ①開始時の値を読む ②バリアントの値へ設定 ③読み返す。nil = 撮ってよい。非 nil = 撮らない理由(呼び手は `restore()` を呼ぶ)
    public mutating func begin() -> String? {
        let budget = DisplayCommandBudget.normal
        let first = transport.read(budget: budget)
        start = first.observation
        guard start.appearance != nil || start.textSize != nil else {
            return "could not read the device's display settings (\(first.failure ?? "no value")); nothing was changed"
        }
        // 書かないキーは基準の値(DisplayExpectation の規則 = run と同じ)
        let target = DisplayExpectation(appearance: variant.appearance, textSize: variant.textSize)
        let keys = DisplaySettingsPlan.keysToSet(expected: target, observed: start, handling: Set(DisplayKey.allCases))
        guard !keys.isEmpty else { return nil }
        let applied = transport.apply(DisplaySettingsPlan.change(keys: keys, target: target, restoreLarger: nil), budget: budget)
        if let failure = applied.failure { return "could not set variant \"\(variant.name)\": \(failure)" }
        let back = transport.read(budget: budget)
        let still = DisplaySettingsPlan.keysToSet(expected: target, observed: back.observation, handling: keys)
        guard still.isEmpty else {
            let detail = DisplayKey.allCases.filter { still.contains($0) }.map {
                "\($0.rawValue): expected \(target.value($0)), read back \(back.observation.value($0) ?? "nothing")"
            }.joined(separator: "; ")
            return "could not set variant \"\(variant.name)\" (\(detail))"
        }
        return nil
    }

    /// ⑦開始時の値へ戻して読み返す。返すのは応答に添える1行
    public func restore() -> String {
        let budget = DisplayCommandBudget.normal
        let now = transport.read(budget: budget)
        var keys: Set<DisplayKey> = []
        var unrestorable: [String] = []
        var appearance: FTAppearance?
        var textSize: FTTextSize?
        if let was = start.appearance, now.observation.appearance != was {
            if let parsed = FTAppearance.parse(was) { appearance = parsed; keys.insert(.appearance) } else { unrestorable.append("appearance \(was)") }
        }
        if let was = start.textSize, now.observation.textSize != was {
            if let parsed = FTTextSize.parse(was) { textSize = parsed; keys.insert(.textSize) } else { unrestorable.append("textSize \(was)") }
        }
        let larger = DisplaySettingsPlan.largerToRestore(atStart: start.largerAccessibilitySizes,
                                                         now: now.observation.largerAccessibilitySizes)
        let target = DisplayExpectation(appearance: appearance, textSize: textSize)
        let change = DisplaySettingsPlan.change(keys: keys, target: target, restoreLarger: larger)
        var problems: [String] = unrestorable.map { "the starting \($0) is not a value this tool can set" }
        if !change.isEmpty {
            let applied = transport.apply(change, budget: budget)
            if let failure = applied.failure {
                problems.append(failure)
            } else {
                let back = transport.read(budget: budget)
                for key in DisplaySettingsPlan.keysToSet(expected: target, observed: back.observation, handling: keys) {
                    problems.append("\(key.rawValue): expected \(target.value(key)), read back \(back.observation.value(key) ?? "nothing")")
                }
            }
        } else if now.failure != nil, now.observation.appearance == nil, now.observation.textSize == nil {
            problems.append(now.failure ?? "could not read the device")
        }
        let was = DisplaySettingsEngine.describe(start)
        if problems.isEmpty { return "display settings returned to the starting values (\(was))" }
        return "⚠️ could not return the display settings to the starting values (\(was)): \(problems.joined(separator: "; "))"
    }
}
