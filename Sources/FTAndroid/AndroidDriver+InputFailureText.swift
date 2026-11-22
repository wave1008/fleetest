// AndroidDriver+InputFailureText.swift
// type / clearInput / pressEnter の失敗を読み手の次の一手へ書き換える文(純関数)と、文中の改行の注記の文。

import Foundation
import FTCore

extension AndroidDriver {
    /// 本文を打ち終えた後の Enter の失敗に「本文は打たれ済み」を足す(純関数)。これを言わないと、読み手は
    /// 何も打たれていないと読んで type を撃ち直し、本文を二重に入れる。pressEnter 単体の文言(「tap the field」)は
    /// 本文が届いた後の状況には合わないので、ここで前置きする
    static func enterAfterTypedBody(_ error: DriverError) -> DriverError {
        let note = "The text was already typed into the field; only the trailing Enter failed (do not type the text again)."
        switch error {
        case .badResponse(let status, let body):
            return .badResponse(status: status, body: "\(note) \(body)")
        case .bridgeUnreachable(let context, let detail):
            return .bridgeUnreachable(context: context, detail: "\(note) \(detail)")
        case .notDelivered(let context, let detail):
            // Enter は未送でも本文は届いている
            return .deliveryUnknown(context: context, detail: "\(note) The Enter key was not sent. \(detail)")
        case .deliveryUnknown(let context, let detail):
            return .deliveryUnknown(context: context, detail: "\(note) \(detail)")
        case .bridgeConnectionRefused, .bridgeIdentityMismatch, .staleRef, .systemAlertBlocked, .argumentRejected, .displayNotApplied:
            return error
        }
    }

    /// **ref 無しの type がフォーカス不在で落ちたとき**の書き換え(純関数 = 単体テストで固定)。
    /// nil = そのままのエラーでよい。
    ///
    /// ブリッジの文面は「tap the field by ref first」だが、**その tap が効かなかったからここに来る**
    /// (受け手報告)。Android の入力欄は容器(TextInputLayout 等)と中身
    /// (TextInputEditText)に分かれることがあり、**容器を叩いても入力フォーカスは中身へ移らない** ——
    /// しかも容器のほうが id を持つので、`#id` を書くと容器に解決する。
    /// 読み手が次に打つ手が分かる形にする = **セレクタを取る `type` へ寄せる**
    /// (解決とフォーカスをツール側が引き受ける)。ref 付きで落ちた場合は別の話なので触らない
    /// `front` = 落ちた直後の前面パッケージ(不明は nil)。`com.android.systemui` なら、欄が無いのではなく覆いが
    /// 入力フォーカスを持っている(シェードを開いたままの ft_type が「ref でタップせよ」と言い、ref のタップは覆いで断られる袋小路だった)
    /// `keyboardShown` = 落ちた直後にソフトキーボードが出ている(横向きの CMP は欄を叩くとキーボードが欄を押し出して
    /// 木から消し、ブリッジが焦点の欄を掴めない。容器の話ではない)
    static func typeNoFocusAdvice(after error: DriverError, hadRef: Bool, front: String? = nil,
                                  lastTreePackage: String? = nil, keyboardShown: Bool = false,
                                  fieldTypedSinceLastTap: Bool = false) -> DriverError? {
        guard !hadRef, case .badResponse(let status, let rawBody) = error,
              rawBody.contains(noInputFocusMarker) else { return nil }
        // 注入器の「by ref」は MCP の言い方で、DSL に ref は無い。下で呼び手どちらにも従える対処を足すので落とす(41周目 alocal F2)
        let body = rawBody.replacingOccurrences(of: bridgeRefAdvice, with: "")
        if let advice = noFocusFrontAdvice(after: error, front: front, lastTreePackage: lastTreePackage) { return advice }
        // **対処は「閉じてからセレクタで打つ」だけ**: View の画面は窓が縮むと欄の高さが 0 に潰れ、端末から焦点そのものが消える
        // (Pixel 3a の E2E-Android の #field_multiline: tap の直後に焦点の View が 0 件・閉じても焦点は戻らず、セレクタ無しの打ち直しは
        // また赤・閉じた後のセレクタの type は通った)。キーボードを出したままのセレクタの type は欄が木に無いので断られる
        if keyboardShown {
            return DriverError.badResponse(status: status, body: body
                + " — the soft keyboard is showing: the window shrank to make room for it, and the field you tapped may have been"
                + " squeezed out of the accessibility tree or lost input focus altogether (a person can still type on the keyboard,"
                + " but nothing here can say which field receives it). Close the keyboard (hideKeyboard), then type by selector:"
                + " type(<selector>, \"…\") focuses the field again")
        }
        // 最後の tap の後に type が通っている = 叩いた容器の話ではなく、焦点を持っていた欄が画面の外へ送られて木から消えた
        // (Flutter は画面外の欄を木から外し、焦点も消える)
        if fieldTypedSinceLastTap {
            return DriverError.badResponse(status: status, body: body
                + " — the field that had input focus was typed into earlier and has since left the accessibility tree (scrolled out of"
                + " the list or pushed off the screen), so no field has focus now. Write type(<selector>, \"…\") to focus and type"
                + " into a field by selector (scroll to it first if it is off the screen)")
        }
        // 前に tap があったかは分からない(何も叩いていない画面でも来る = 41周目 amax F1)ので、どちらの場合にも合う形で言う
        return DriverError.badResponse(status: status, body: body
            + " — no field has input focus: either no field was tapped, or the tap landed on something that does not take"
            + " input focus (on Android an input is often a container (TextInputLayout) wrapping the editable field"
            + " (TextInputEditText), and the id usually sits on the container)."
            + " Write type(<selector>, \"…\") instead: it resolves the editable field and"
            + " focuses it (e.g. type(\".textField[1]\", \"…\"))")
    }

    /// 覆い(シェード・クイック設定・ロック画面)が入力フォーカスを持つとき、ref 無しの clearInput を断る文
    static func coveredFieldError() -> DriverError {
        .badResponse(status: 422, body: "nothing was cleared: com.android.systemui (the notification shade, quick settings or the lock"
            + " screen) is in front and holds the input focus, so the app's field is not the one that would be cleared."
            + " Close it first (DSL: back() / MCP: ft_navigate back, or unlock the device), then retry.")
    }

    /// 欄ではなく前面が原因のフォーカス不在(type / clearInput 共通)。前面からは言えないとき nil
    static func noFocusFrontAdvice(after error: DriverError, front: String?, lastTreePackage: String?) -> DriverError? {
        guard case .badResponse(let status, let body) = error else { return nil }
        if front == "com.android.systemui" {
            return DriverError.badResponse(status: status, body: body
                + " — com.android.systemui (the notification shade, quick settings, the lock screen or an assistant) is"
                + " in front and holds the input focus, so the field is not the problem. Close it first"
                + " (DSL: back() / MCP: ft_navigate back, or unlock the device), then retry.")
        }
        // 直近の木のアプリが前面から消えている(落ちた・離れた)と、欄の話ではない
        if let front, let lastTreePackage, front != lastTreePackage {
            return DriverError.badResponse(status: status, body: body
                + " — \(front) is in front, not \(lastTreePackage) (the app of the last tree): that app may have crashed or"
                + " been left, so there is no field to type into. Bring the app back first (DSL: tapAppIcon() or launchApp() / MCP: ft_launch).")
        }
        return nil
    }

    /// 文中の改行は文字として書く(Enter にしない)事実。iOS は Return として届くので Android だけ言う。
    /// 単一行の欄向けの対処(欄のアクションは発火しない・pressEnter で分ける)は**欄が単一行と分かるときだけ**足す
    /// (`singleLineFieldMarker` = ブリッジが /type の note に足した事実。複数行の欄では文字として入るのが正しい結果)
    static let innerNewlineFact = "the newline inside the text was written into the field as a character, not pressed as Enter"
        + " (on Android only a trailing newline is sent as Enter)"
    static let innerNewlineSingleLineAdvice = ": a single-line field keeps it as a character and its action"
        + " (search, done) does not fire — to press Enter between the parts, type them separately with pressEnter in between"
    /// InputInjector.SINGLE_LINE_FIELD_NOTE と同期(変わると単一行の対処が出なくなるだけ)
    static let singleLineFieldMarker = "the field that took the text is single-line"

    /// 改行の注記の文(純関数)。`bridgeNote` = その type で受け取ったブリッジの note
    static func innerNewlineNote(bridgeNote: String?) -> String {
        guard let bridgeNote, bridgeNote.contains(singleLineFieldMarker) else { return innerNewlineFact }
        return innerNewlineFact + innerNewlineSingleLineAdvice
    }
}
