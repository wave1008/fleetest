// ResolvedVariant.swift
// 解決済みのバリアント(名前 + その表示条件の値)。`ScenarioHost.run` が受け、結果・イベント・`--failed` の記録の単位の鍵(`unitKey`)になる。
// プロファイルの `variants` の読み取りと展開は後続の段。それまで呼び手は nil(バリアントの無い run)を渡す。

import Foundation

public struct ResolvedVariant: Hashable, Sendable {
    public let name: String
    public let appearance: FTAppearance?
    public let textSize: FTTextSize?
    /// `FTOrientation` の文字列(プロファイルの `orientation` と同じ)
    public let orientation: String?

    public init(name: String, appearance: FTAppearance?, textSize: FTTextSize?, orientation: String?) {
        self.name = name
        self.appearance = appearance
        self.textSize = textSize
        self.orientation = orientation
    }

    public func unitKey(scenarioID: String) -> ScenarioUnitKey {
        ScenarioUnitKey(id: scenarioID, variant: name)
    }
}

extension Optional where Wrapped == ResolvedVariant {
    /// 記録・イベントへ載せる名前(バリアントの無い run は nil = 欄ごと省く)
    public var variantName: String? { self?.name }

    /// 子へ渡す向き。バリアントの向きが先(全バリアントが明示する規則なので前のシナリオの向きは必ず上書きされる)、無ければプロファイルの `orientation`
    public func childOrientation(fallback: FTOrientation?) -> FTOrientation? {
        self?.orientation.flatMap(FTOrientation.parse) ?? fallback
    }
}
