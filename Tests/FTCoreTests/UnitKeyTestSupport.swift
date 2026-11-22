import FTCore

/// テスト用: ID の並び → バリアント無しの単位の並び(バリアントを持たない run の鍵)
func unitKeys(_ ids: [String]) -> [ScenarioUnitKey] { ids.map { ScenarioUnitKey(id: $0, variant: nil) } }
