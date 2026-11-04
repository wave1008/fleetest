// `tap(入力欄)` → `type("文字列")` を成立させるための救済。
//
// **これは Shirates(Classic)からの伝統的な書き方**で、利用者はこの形をそのまま移植してくる。
// ところが Android の入力欄は**容器**(Material の `TextInputLayout` 等)と**中身**
// (`TextInputEditText`)に分かれることがあり、**id は容器側に付くことが多い** ——
// `tap("#id")` は容器に解決し、a11y のクリックでは中身へ入力フォーカスが移らない。
// 結果、次の `type` が「フォーカスが無い」で落ちる(受け手報告)。
//
// **回避策を書かせない**(利用者の自然な書き方をツール側で吸収する)。ただし
// **推測はしない** —— 入れる先が一意に決まるときだけ救済し、決まらなければそのまま失敗させる。
//
// 判定はここ1箇所(`StepExecutor` が転送する)。**焦点が立っているかは木から読む**
// (`ElementInfo.focused` は iOS xcuitest=`hasKeyboardFocus` / iOS in-app=`isFirstResponder` /
// Android=`isFocused` の3ブリッジとも申告する)。

import Foundation

public enum InputFocusRescue {

    /// **救済すべきか**: 焦点のある要素が、叩いた要素そのものでも内側でもないか。
    ///
    /// - 焦点がどこにも無ければ救済すべき(true)。**申告が無いこと**(全要素 nil)も含める ——
    ///   その場合に救済へ進んでも、入れる先が一意に決まらなければ何もしないので、
    ///   誤って別の欄へ入れることはない
    /// - 焦点が叩いた要素そのもの、またはその内側にあるなら救済しない(false)——
    ///   フォーカス中要素へそのまま送る速い経路
    /// - **焦点が叩いた対象の外の別の欄に残っている**なら救済すべき(true)。Android は
    ///   容器(TextInputLayout)を叩いても前の EditText の焦点を外さないことがあり、
    /// ここを「焦点が無い」としてしまうと `type` が前の欄へ送られて誤って緑になる
    ///
    /// **ref では突き合わせない** —— `tapped` はタップ前の木、`elements` はタップ後に撮り直した木で、
    /// ref は木ごとに振り直される(別の要素が同じ番号を持ちうる)。同一の要素かは id + 型で見て、
    /// id が無ければ位置(焦点のある要素の中心が叩いた要素の矩形に入るか)で見る
    public static func focusIsElsewhere(from tapped: ElementInfo, in elements: [ElementInfo]) -> Bool {
        guard let focused = elements.first(where: { $0.focused == true }) else { return true }
        // 叩いた要素が撮り直した木に居ない = 画面が変わった。焦点が立っているならそこへ送る(別の欄を推測しない)
        guard let tappedFrame = currentFrame(of: tapped, in: elements) else { return false }
        if let id = tapped.identifier, !id.isEmpty, focused.identifier == id, focused.type == tapped.type {
            return false
        }
        return !contains(tappedFrame, centreOf: focused.frame)
    }

    /// 叩いた要素の**撮り直した木での枠**。キーボードが出ると一覧が押し上げられ(Flutter・View)、叩いた時点の枠のままでは
    /// 焦点のある欄の中心が枠の外に出て「焦点はよそ」と読み、**古い枠の中に来た隣の欄**を選んで打つ。
    /// id + 型がちょうど1個に決まるときだけ撮り直した木の枠を使い、複数なら叩いた時点の枠のまま。
    /// **id があるのに撮り直した木に1個も無いときは nil**(画面が遷移した: 遷移前の行の枠を残すと、新しい画面の
    /// 無関係な欄がその枠に重なって救済の入れ先に選ばれ、緑で別の欄へ打つ = inapp F7)。id が無い要素は枠のまま
    static func currentFrame(of tapped: ElementInfo, in elements: [ElementInfo]) -> FTRect? {
        guard let id = tapped.identifier, !id.isEmpty else { return tapped.frame }
        let same = elements.filter { $0.identifier == id && $0.type == tapped.type }
        if same.isEmpty { return nil }
        return same.count == 1 ? same[0].frame : tapped.frame
    }

    /// 直前に叩いた要素から「入れるべき欄」を決める。**一意に決まらなければ nil**。
    ///
    /// - 叩いた要素そのものが入力欄ならそれ(フォーカスだけが立たなかった形)
    /// - 叩いたのが容器なら、その中にある**ただ1つ**の入力欄
    /// - 入力欄が0個、または2個以上あるなら nil(どれに入れるべきかツールには言えない)
    ///
    /// 突き合わせは**新しく撮り直した木**に対して行う(ref は木ごとに振り直されるので、
    /// 前の木の ref をそのまま使ってはいけない)。位置は**中心が容器の矩形に入るか**で見る ——
    /// 容器と中身は数 px ずれることがあり、厳密な包含だと落ちる
    /// `before` = 叩く直前の木。**入れ先は叩く前からそこにあった欄だけ** —— 遷移の途中の木には叩いた行と新しい画面の欄が
    /// 同居するので、枠の包含だけでは遷移先の無関係な欄を選んで緑で打つ(inapp F7)。無ければ(読めなかった)枠だけで見る
    public static func fieldToType(after tapped: ElementInfo, in elements: [ElementInfo],
                                   before: [ElementInfo]?) -> ElementInfo? {
        guard let frame = currentFrame(of: tapped, in: elements) else { return nil }
        let candidates = elements.filter { element in
            SnapshotRenderer.textInputTypes.contains(element.type) && element.enabled
                && contains(frame, centreOf: element.frame)
                && (before.map { existed(element, in: $0, tapped: tapped) } ?? true)
        }
        guard candidates.count == 1 else { return nil }
        return candidates.first
    }

    private static func existed(_ field: ElementInfo, in before: [ElementInfo], tapped: ElementInfo) -> Bool {
        if let id = field.identifier, !id.isEmpty {
            return before.contains { $0.identifier == id && $0.type == field.type }
        }
        return before.contains {
            $0.type == field.type && SnapshotRenderer.textInputTypes.contains($0.type)
                && contains(tapped.frame, centreOf: $0.frame)
        }
    }

    /// **焦点は叩く前からそこにあったか**(= 叩いても動かなかった残りか)。偽なら焦点は叩いた操作が動かした先
    /// (検索ボタンが開いた検索欄など)で、そこへ入れるのが意図どおり。真のときだけ「前の欄へ入った」恐れがある。
    /// 叩く前の木に焦点が無ければ偽。同一かは `focusIsElsewhere` と同じく id + 型、id が無ければ中心の位置で見る
    public static func focusWasAlreadyThere(before: ElementInfo?, after focused: ElementInfo) -> Bool {
        guard let before else { return false }
        if let id = before.identifier, !id.isEmpty {
            return focused.identifier == id && focused.type == before.type
        }
        return contains(before.frame, centreOf: focused.frame)
    }

    /// 対象がいま焦点を持つ欄か。**対象自身が focused、または焦点のある要素が対象の枠の中(同じ枠を含む)に収まる**(外側の容器が
    /// 焦点を持つ形は数えない = 全画面の容器で免除しない)。Flutter・Compose は焦点が欄の内側/外側のノードに立ち、対象に focused が
    /// 付かないことがある。呼び手は MCP(`MCPServer.typesWithoutTouching`)。**DSL の `reachPastKeyboard` には使わない** ——
    /// XCUITest ランナーが叩くのを省くのは ref 自身が焦点を持つとき(`alreadyFocusedInput`)だけで、内側の要素が焦点を持つ欄は
    /// 中心を叩く = キーボードの下ならキーを押す(ランナーの焦点の判定を揃えてから広げる)
    public static func holdsFocus(_ target: ElementInfo, in tree: [ElementInfo]) -> Bool {
        if target.focused == true { return true }
        let slack = Double(FocusLanding.sameElementFrameTolerance)
        func contains(_ outer: FTRect, _ inner: FTRect) -> Bool {
            inner.x >= outer.x - slack && inner.y >= outer.y - slack
                && inner.x + inner.width <= outer.x + outer.width + slack
                && inner.y + inner.height <= outer.y + outer.height + slack
        }
        return tree.contains { other in
            other.focused == true && other.ref != target.ref && contains(target.frame, other.frame)
        }
    }

    /// **直前の操作が tap で、その tap がこの欄を叩いていたか**(焦点の印を木に出さない構成 = Flutter の in-app の木で、焦点のある欄への
    /// 打鍵の免除を効かせる。横向きの `tap` → `type` が「キーボードの下の欄」で断られた)。
    /// 叩いた欄と同じ要素(id + 型。id が無ければ枠)で、**木のどの要素も別の場所の焦点を申告していない**ときだけ真
    /// (他の欄が焦点を持っていれば、叩いても焦点は動いていない)。キーボードの表示は呼び手が見る
    public static func tapFocusedIt(_ element: ElementInfo, priorTap: ElementInfo?, in elements: [ElementInfo]) -> Bool {
        guard let priorTap else { return false }
        if let id = priorTap.identifier, !id.isEmpty {
            guard element.identifier == id, element.type == priorTap.type else { return false }
        } else {
            guard element.identifier.map({ $0.isEmpty }) ?? true, element.frame == priorTap.frame else { return false }
        }
        return !elements.contains { $0.focused == true && !contains(element.frame, centreOf: $0.frame) }
    }

    private static func contains(_ rect: FTRect, centreOf inner: FTRect) -> Bool {
        let x = inner.x + inner.width / 2
        let y = inner.y + inner.height / 2
        return x >= rect.x && x <= rect.x + rect.width
            && y >= rect.y && y <= rect.y + rect.height
    }
}
