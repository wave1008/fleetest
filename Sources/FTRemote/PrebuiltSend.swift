// シナリオ実行バイナリを `gzip -1 | ssh` で送るときの受け側(送り手は RemoteRunDispatcher.sendCompressed)。

public enum PrebuiltSend {
    /// 送り手の `gzip -1` の出力を stdin で受けて置く向こうのコマンド。途中の `.part` から mv する
    /// (途切れた転送で実行できない半端なファイルを本来の名前に残さない)。実行権は gunzip が持たないので付ける
    public static func receiveCommand(stagingDir: String, remotePath: String) -> String {
        let part = RemoteShell.quote(remotePath + ".part")
        return "mkdir -p \(RemoteShell.quote(stagingDir)) && gunzip -c > \(part) && chmod 755 \(part) && mv \(part) \(RemoteShell.quote(remotePath))"
    }
}
