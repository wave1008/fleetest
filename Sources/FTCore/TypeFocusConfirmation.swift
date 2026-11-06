/// ロケータなしの type の後、木に入力の焦点を申告する要素が無いときの判定(MCP の `ft_type` と DSL の `type("…")` が共有する)。
/// **共有するのは判定だけ**で、文言は呼び手ごとに持つ(MCP: `noFocusNote` / DSL: 注記 `type-focus-not-reported`)。
public enum TypeFocusConfirmation {
    public enum Verdict: Equatable, Sendable {
        /// 焦点を申告する要素がある(打った先を名指しできる)
        case reported
        /// 焦点の申告が無いが、キーボードが出ている・木が空・WebView が載っている = 入力接続はあっても焦点が木に出ない形
        /// (横向きの全画面 IME・WebView の中の欄・木に載らない隠れた入力欄)。打った先は確かめられなかった
        case unconfirmable
        /// 焦点の申告が無く、上のどれでもない = 打った文字の行き先が無かったかもしれない
        case nowhere
    }

    public static func verdict(_ snapshot: SnapshotResponse) -> Verdict {
        if snapshot.elements.contains(where: { $0.focused == true }) { return .reported }
        if KeyboardWait.isShown(snapshot) || snapshot.elements.isEmpty
            || snapshot.elements.contains(where: { $0.type == "webView" }) {
            return .unconfirmable
        }
        return .nowhere
    }
}
