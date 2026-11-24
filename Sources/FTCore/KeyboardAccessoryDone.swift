// iOS の WebView の入力欄は、キーボードの上に OS の入力補助バー(Previous / Next / Done)を出す。バーは `keyboardFrame` に
// 含まれず、WebView のページは空きの点が無い(`KeyboardDismissPoint` が候補を出せない)ので、hideKeyboard は閉じる手段を失って
// Enter まで送っていた(フォームが送信される)。人が押す Done を、木に載っている OS のバーに限って押す。
//
// **OS のバーだけを対象にする**: アプリ独自の入力補助(チャットの送信ボタン付きバー等)の最後のボタンは「送信」かもしれず、
// 押すと副作用が起きる。OS のバーは型 `toolbar` と識別子 `Toolbar`(ローカライズされない)で、キーボードの真上に付く。
// 押すのは Done = バーの中の押せるボタンの最後(左から右の言語。Previous / Next は先に並ぶ)

import Foundation

public enum KeyboardAccessoryDone {
    /// OS の入力補助バーの識別子。XCUITest が木に載せる値で、表示言語に依らない
    static let toolbarIdentifier = "Toolbar"

    /// `keyboard`(申告されたキー面)のすぐ上にある OS のバーの Done。無ければ nil。
    /// 「すぐ上」= バーの下端とキー面の上端の差がバー2本分以内。間に予測変換の帯が挟まる(実測: バーの下端 528・キー面の上端 583・
    /// バーの高さ 48 = 差 55pt)。画面の上の方のバーはこの範囲に入らない
    public static func target(in elements: [ElementInfo], keyboard: FTRect) -> ElementInfo? {
        for toolbar in toolbars(in: elements, keyboard: keyboard) {
            let buttons = LocatorResolver.descendants(of: toolbar, in: elements)
                .filter { $0.type == "button" && $0.enabled && $0.frame.width > 0 && $0.frame.height > 0 }
            if let done = buttons.last { return done }
        }
        return nil
    }

    /// キー面のすぐ上の OS のバー(上の規則)。キーボードと一緒に消えるのが正当なので、閉じた後に「消えた要素」と数えない側も
    /// この1か所を使う(`StepExecutor.allElementsGoneAfterKeyboardClose`。キー面に接した帯だけを見ると、予測変換の帯を挟んで
    /// 浮いた Safari の Web の入力欄のバーが漏れ、閉じた後に対象を撃たず赤になった)
    public static func toolbars(in elements: [ElementInfo], keyboard: FTRect) -> [ElementInfo] {
        elements.filter { toolbar in
            guard toolbar.type == "toolbar", toolbar.identifier == toolbarIdentifier, toolbar.frame.height > 0 else { return false }
            return abs(toolbar.frame.y + toolbar.frame.height - keyboard.y) <= toolbar.frame.height * 2
        }
    }
}
