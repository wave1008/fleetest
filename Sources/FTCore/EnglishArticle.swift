// 要素の型など、実行時に決まる名詞の前の不定冠詞(固定の "a" は "a other"・"a image" と崩れた = 探索 11/27 alocal F1)。
// 綴りの先頭の母音字だけで決める(型名は camelCase の英単語 = "user" のような例外の読みは来ない)

public enum EnglishArticle {
    /// "an other" / "a button"
    public static func indefinite(_ noun: String) -> String {
        guard let first = noun.first?.lowercased() else { return "a \(noun)" }
        return ("aeiou".contains(first) ? "an " : "a ") + noun
    }
}
