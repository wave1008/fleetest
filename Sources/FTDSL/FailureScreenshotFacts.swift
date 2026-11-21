// FailureScreenshotFacts.swift

import Foundation
import FTCore

/// 失敗時の絵が写さないと言える事実の判定(MCP・DSL で共有する置き場。実行機の static にしない)
enum FailureScreenshotFacts {
    /// 失敗時の木でキーボードが出ていて、焦点の要素が secureTextField か。OS は secure 入力の間、キーボードとパスワードの中身を
    /// 画面の撮影から除く(木は `keyboardShown` と値を答える。測定: 焦点が secure かどうかと 18/18 で一致)。
    /// 焦点を申告しない木・キーボードが出ていない木は false(黙る)
    static func omitsSecureKeyboard(_ snapshot: SnapshotResponse) -> Bool {
        guard KeyboardWait.isShown(snapshot) else { return false }
        return snapshot.elements.contains { $0.focused == true && $0.type == "secureTextField" }
    }
}
