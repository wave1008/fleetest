/// 検証の「含む」の唯一の定義(`*Contains` / `*ContainsNot` / `this*` / セレクタの `textContains=`)。
/// **空の期待値は「含む」**(hasPrefix("") / hasSuffix("") と同じ向き)。Swift の `String.contains("")` は false を返すので、
/// 呼び手ごとに書くと否定形(`textContainsNot("")`)が黙って緑になる(41・43周目に経路を変えて2度出た)。
/// 素の `.contains(期待値)` を検証の経路に書かない = `TextContainmentSingleSourceTests` が走査で落とす
public enum TextContainment {
    public static func contains(_ actual: String, _ expected: String) -> Bool {
        expected.isEmpty || actual.contains(expected)
    }
}
