// ScenarioUnitKey.swift
// 実行の単位の鍵(シナリオ ID × バリアント。バリアントの無い run では variant = nil)。
// 並べ替え・割り振り・欠落の照合・記帳は ID だけの文字列を鍵にせず、全部この型で持つ(`ScenarioUnitKeyScanTests` が走査で固定)。
// 文字列表現は `ID` / `ID@variant`。`@` はシナリオ ID に現れない(識別子)ので、最初の `@` で割れる。

import Foundation

public struct ScenarioUnitKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public let id: String
    public let variant: String?

    public init(id: String, variant: String?) {
        self.id = id
        self.variant = variant
    }

    /// `ID` / `ID@variant`(表示・`--scenario` の渡し方・ログ)。`parse` と対
    public var description: String { variant.map { "\(id)@\($0)" } ?? id }

    /// `description` の逆。`@` が無ければ variant = nil。`@` の後ろが空なら nil(壊れた形)
    public static func parse(_ text: String) -> ScenarioUnitKey? {
        guard let at = text.firstIndex(of: "@") else {
            return text.isEmpty ? nil : ScenarioUnitKey(id: text, variant: nil)
        }
        let id = String(text[..<at]), variant = String(text[text.index(after: at)...])
        guard !id.isEmpty, !variant.isEmpty else { return nil }
        return ScenarioUnitKey(id: id, variant: variant)
    }
}

/// クラス × バリアント(寄せる属性の「同じバリアントのまとまり」。`@RunInOrder` の失敗の記帳・母数の鍵)
public struct ClassVariantKey: Hashable, Sendable {
    public let className: String
    public let variant: String?

    public init(className: String, variant: String?) {
        self.className = className
        self.variant = variant
    }
}

extension ScenarioInfo {
    /// この ID の単位の鍵。バリアントを持たない経路(ScenarioInfo は ID だけ)は `variant: nil` を明示して作る
    public func unitKey(variant: String?) -> ScenarioUnitKey { ScenarioUnitKey(id: id, variant: variant) }
}

extension ScenarioRunRecord {
    /// 記録の単位の鍵。**この段では記録に variant が無いので nil**(欠落の照合は「記録の ID + variant(無ければ nil)」で作る)。
    /// 記録に variant を足す段でここを変える(欠落の照合・集計はこの1か所を通す)
    public var unitKey: ScenarioUnitKey { ScenarioUnitKey(id: scenarioID, variant: nil) }
}
