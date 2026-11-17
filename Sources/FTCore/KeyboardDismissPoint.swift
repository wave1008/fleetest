// KeyboardDismissPoint.swift
// iOS の hideKeyboard が叩く「何も起きない点」の候補(純粋関数。呼び手は StepExecutor.executeIOSHideKeyboard)。
// iOS にはキーボードを閉じる共通の手段が無い(Escape・resignFirstResponder・nil ターゲットの sendAction は Compose で
// 不発 = docs/shirates-parity.md)ので、人と同じく「入力欄の外を叩く」。閉じるかはアプリ次第で、閉じなければ呼び手が失敗にする。
//
// 探す範囲は**表示されているキーボードの上側の領域を下から上へ**(ユーザー決定。焦点のある欄を起点にする案は、
// Compose・Flutter が焦点を木に出さないので使えなかった)。行を下から上へ、各行は左から右へ見る。
// 「空き」= どの要素にも重ならない点か、**画面幅いっぱいの・操作できない入れ物だけ**に重なる点(葉 = 文字・画像には乗らない)。
// 幅で絞るのは、トーストやカードのような重なった入れ物の余白を「空き」と読まないため(叩くとトーストが消える・操作が起きる)。
// 木に出ない重ねウィンドウ(`overlays` = スナップショットの overlayWindowFrames)の上も除く。
// 候補は入れ物ごとに代表1点(最も下の点。同じ入れ物の背景は当たり判定でも同じ答えになる)。
// 木に載らないステータスバー・別のウィンドウ(トースト等)は、呼び手が叩く前にブリッジの当たり判定(`AppDriver.tapProbe`)で
// 確かめる。**木に載らない透明な押せる仕掛けは避けられない**(既知の限界。叩いた後に画面が変わったら呼び手が注記に出す)。

import Foundation

public enum KeyboardDismissPoint {
    public struct Choice: Sendable {
        public let x: Double
        public let y: Double
    }

    /// 叩くと何かが起きうる型。ブリッジの操作可能な型・入力欄・タップを受け止める型に加え、中身が木に出ない面(WebView・地図)
    static let unsafeTypes: Set<String> = BridgeSnapshotThinning.operableTypes
        .union(TapTargetGeometry.interactiveTypes)
        .union(["secureTextField", "searchField", "textView", "radioButton", "segmentedControl", "stepper",
                "picker", "pickerWheel", "toggle", "webView", "map", "keyboard", "key"])

    /// 走査の格子の目の数(画面の横幅の何分の1か)。画面の大きさに比例させる(固定の pt を置かない)
    static let gridColumns = 24

    /// キーボードの縁に接した・裏へ押し込まれた押せる部品(タブバー・ツールバー・ボタン類)の当たり判定が木の枠の外へはみ出す幅(pt)。
    /// **根拠**: E2E-iOS(SwiftUI・XCUITest)の実測で、キーボード裏のタブ(木では上端 y=548)は 11pt 上の y=537 で反応し、
    /// 23pt 上の y=525 では反応しなかった。小さい画面の CMP ではタブバーとキーボードの 8pt の隙間(木に載らない Scaffold の下端)が叩けなかった。
    /// 両方を覆い実測の外側に収まる値。**尽きたとき**(縁の近くに空きが無い)は候補が空になり、呼び手が叩かず次の手段(Enter)へ進む
    static let edgeHitSlop: Double = 16

    /// 押せる部品の当たり判定の余白を持つ入れ物の型(子ではなく自身の枠。タブの間の隙間を空きと読まない)
    static let slopContainerTypes: Set<String> = ["tabBar", "toolbar"]

    /// 押せる部品の当たり判定が、キーボードの縁から離れた場所でも枠の外へはみ出す幅(pt)。`edgeHitSlop` とは別に持つ(片方を詰めても他方は動かさない)。
    /// **根拠**: E2E-iOS の WebView 画面(iPad の Simulator)で、戻るボタン #btn_back (16,48 56x62) の枠の 1pt 右 (73,78)(横向き)と
    /// 12pt 下 (52,122)(縦向き)のタップが戻るボタンを押してホームへ遷移した = この文脈の実測は「12pt では反応する」だけ。反応しない距離は測っていない。
    /// **尽きたとき**(この余白の外に空きが無い)は呼び手が OS の入力補助バーの Done を先に探し、無ければ余白の中の空き(`candidatesIgnoringControlSlop`)を試す
    static let controlHitSlop: Double = 16

    /// **周り全体に当たり判定の余白(`controlHitSlop`)を持つ押せる部品の型**(叩くと動く部品)。
    /// **セル・clickable・テキストビュー・WebView・地図・文字の欄は入れない** —— 縦長・全幅の面や詰めて並ぶ欄で、多くの画面の空きが余白の中だけになる
    static let slopControlTypes: Set<String> = [
        "button", "link", "switch", "checkBox", "radioButton", "tab", "toggle", "segmentedControl", "stepper", "menuItem",
    ]

    /// 押せる部品の当たり判定の余白(`controlSlopRects`)の外の空き。空なら呼び手は OS の入力補助バーの Done を先に探し、
    /// 無ければ `candidatesIgnoringControlSlop` を試す(余白の中の空きを叩くのは、副作用の無い手段が尽きてから = Enter の手前)
    public static func candidates(elements: [ElementInfo], screen: FTRect, keyboard: FTRect,
                                  overlays: [FTRect]) -> [Choice] {
        candidates(elements: elements, screen: screen, keyboard: keyboard, overlays: overlays,
                   controlSlop: controlSlopRects(elements))
    }

    /// 押せる部品の余白を除かない空き(部品の枠の上とキーボードの縁の帯は除く)。`candidates` が空で Done も無いときだけ使う
    public static func candidatesIgnoringControlSlop(elements: [ElementInfo], screen: FTRect, keyboard: FTRect,
                                                     overlays: [FTRect]) -> [Choice] {
        candidates(elements: elements, screen: screen, keyboard: keyboard, overlays: overlays, controlSlop: [])
    }

    /// 周り全体に余白を持つ部品の枠を `controlHitSlop` だけ広げた矩形。無効な部品・大きさ0の枠・キーボードの子孫は除く
    /// (キーボードの上端より上のタッチはアプリへ届く = 予測変換のボタンの余白は上の行を潰すだけ)
    static func controlSlopRects(_ elements: [ElementInfo]) -> [FTRect] {
        let keyboardRefs = keyboardSubtreeRefs(elements)
        return elements.filter {
            !keyboardRefs.contains($0.ref) && slopControlTypes.contains($0.type) && $0.enabled
                && $0.frame.width > 0 && $0.frame.height > 0
        }.map { inflated($0.frame, by: controlHitSlop) }
    }

    static func candidates(elements: [ElementInfo], screen: FTRect, keyboard: FTRect,
                           overlays: [FTRect], controlSlop: [FTRect]) -> [Choice] {
        let top = screen.y
        let bottom = min(keyboard.y, screen.y + screen.height)
        guard bottom > top, screen.width > 0 else { return [] }
        let step = screen.width / Double(gridColumns)
        let keyboardRefs = keyboardSubtreeRefs(elements)
        func scan(_ xs: [Double]) -> [Choice] {
            var result: [Choice] = []
            var seenContainers: Set<Int> = []  // 入れ物の ref(どの要素にも重ならない点は -1)
            var y = bottom - step / 2
            while y > top {
                for x in xs {
                    guard !overlays.contains(where: { contains($0, x: x, y: y) }),
                          !controlSlop.contains(where: { contains($0, x: x, y: y) }),
                          let container = emptySpotContainer(x: x, y: y, elements: elements, screen: screen,
                                                             keyboardTop: keyboard.y, keyboardRefs: keyboardRefs),
                          seenContainers.insert(container).inserted else { continue }
                    result.append(Choice(x: x, y: y))
                }
                y -= step
            }
            return result
        }
        let allXs = samples(from: screen.x, length: screen.width, step: step)
        // 左右の端の1列(x = step/2 ≒ 8pt)は戻るジェスチャの帯(Flutter の Cupertino 遷移は端から 20pt = kBackGestureWidth)に入り、
        // 叩いても背景の押下にならず閉じない回があった(同じ点が選ばれ続けて 7/25 で閉じなかった)。端の1列を外した点を先に試し、
        // 空きが無ければ全幅へ戻る(1列 = step ≒ 画面幅/24 ≒ 16pt なので外した後の最端は 24pt 以上で帯の外)
        func scanPreferringInterior(_ xs: [Double]) -> [Choice] {
            let interior = xs.filter { $0 - screen.x >= step && screen.x + screen.width - $0 >= step }
            let preferred = interior.isEmpty ? [] : scan(interior)
            return preferred.isEmpty ? scan(xs) : preferred
        }
        // 横向きは左右に切り欠きの帯(safe area)があり、アプリの中身が届かない帯の点は叩いても何も起きず閉じない
        // (iOS 横向きの CMP で毎回 (18,199) を選んで失敗した)。中身の横の範囲の点を先に試し、無ければ全幅へ戻る
        if screen.width > screen.height, let extent = contentHorizontalExtent(elements, screen: screen, keyboardTop: keyboard.y, keyboardRefs: keyboardRefs),
           extent.upperBound - extent.lowerBound < screen.width - step {
            let inside = scanPreferringInterior(allXs.filter { extent.contains($0) })
            if !inside.isEmpty { return inside }
        }
        return scanPreferringInterior(allXs)
    }

    /// 画面幅いっぱいでない・キーボードでない要素の横の範囲(アプリの中身がある帯)。無ければ nil
    static func contentHorizontalExtent(_ elements: [ElementInfo], screen: FTRect, keyboardTop: Double,
                                        keyboardRefs: Set<Int>) -> ClosedRange<Double>? {
        let content = elements.filter {
            !keyboardRefs.contains($0.ref) && $0.frame.y < keyboardTop
                && !TapTargetGeometry.keyboardChromeIdentifiers.contains($0.identifier ?? "") && !isScreenWide($0, screen: screen) && $0.frame.width > 0
                && $0.frame.x + $0.frame.width > screen.x && $0.frame.x < screen.x + screen.width
        }
        guard let lo = content.map({ max($0.frame.x, screen.x) }).min(),
              let hi = content.map({ min($0.frame.x + $0.frame.width, screen.x + screen.width) }).max(),
              hi > lo else { return nil }
        return lo...hi
    }

    /// 区間の中の点。区間が刻みより狭ければ中央の1点
    static func samples(from start: Double, length: Double, step: Double) -> [Double] {
        guard length > step else { return [start + length / 2] }
        return Array(stride(from: start + step / 2, to: start + length, by: step))
    }

    /// その点が「空き」なら、点を含む最も深い入れ物の ref(代表を入れ物ごとに1点にする鍵。どの要素にも重ならない点 = -1)。
    /// **要素が1つも重ならない点も空き**(in-app の木は画面全体を覆う入れ物を持たないことが多い。叩く前に当たり判定で確かめる)
    static func emptySpotContainer(x: Double, y: Double, elements: [ElementInfo], screen: FTRect,
                                   keyboardTop: Double, keyboardRefs: Set<Int>) -> Int? {
        guard !isNearKeyboardEdgeControl(x: x, y: y, elements: elements, keyboardTop: keyboardTop,
                                         keyboardRefs: keyboardRefs) else { return nil }
        let containing = elements.filter { contains($0.frame, x: x, y: y) }
        guard !containing.contains(where: { unsafeTypes.contains($0.type) || isLeaf($0, in: elements)
                  || !isScreenWide($0, screen: screen) }) else { return nil }
        return containing.max(by: { $0.depth < $1.depth })?.ref ?? -1
    }

    /// キーボードの縁(上端から `edgeHitSlop` 以内)に届く押せる部品の、当たり判定の余白(`edgeHitSlop`)の中の点か。
    /// **この帯の除外は余白を後回しにせず必ず除く** —— キーボード裏のタブは縁の上で反応する(実測 = edgeHitSlop の doc)。
    /// 型を問わず(テキストビュー・WebView も)除くのはこの帯の中だけ。帯より上で周り全体の余白を持つのは `slopControlTypes` だけで、
    /// それも後回し(`candidates`)= 縦長のテキストビュー・WebView の脇の狭い余白(その画面で唯一の空き)を失って Enter へ落ちない
    /// `keyboardRefs` = キーボードとその子孫(予測変換バーのボタン等)。キーボードは別のウィンドウで、その上端より上の
    /// タッチはアプリへ届く = 余白は上の行を潰すだけなので除く。裏に押し込まれたアプリの部品(タブバー)は子孫でないので残る
    static func isNearKeyboardEdgeControl(x: Double, y: Double, elements: [ElementInfo], keyboardTop: Double,
                                          keyboardRefs: Set<Int>) -> Bool {
        guard y >= keyboardTop - edgeHitSlop else { return false }
        return elements.contains { element in
            guard !keyboardRefs.contains(element.ref),
                  unsafeTypes.contains(element.type) || slopContainerTypes.contains(element.type),
                  element.frame.y + element.frame.height >= keyboardTop - edgeHitSlop else { return false }
            return contains(inflated(element.frame, by: edgeHitSlop), x: x, y: y)
        }
    }

    static func inflated(_ r: FTRect, by slop: Double) -> FTRect {
        FTRect(x: r.x - slop, y: r.y - slop, width: r.width + 2 * slop, height: r.height + 2 * slop)
    }

    /// 型 `keyboard` の要素とその子孫の ref(木の preorder + depth)
    static func keyboardSubtreeRefs(_ elements: [ElementInfo]) -> Set<Int> {
        var refs: Set<Int> = []
        var keyboardDepth: Int?
        for element in elements {
            if let depth = keyboardDepth, element.depth > depth {
                refs.insert(element.ref)
                continue
            }
            keyboardDepth = nil
            if element.type == "keyboard" {
                keyboardDepth = element.depth
                refs.insert(element.ref)
            }
        }
        return refs
    }

    static func isScreenWide(_ element: ElementInfo, screen: FTRect) -> Bool {
        element.frame.x <= screen.x + 1 && element.frame.x + element.frame.width >= screen.x + screen.width - 1
    }

    /// 木の preorder + depth で、直後の要素が自分より深ければ子を持つ
    static func isLeaf(_ element: ElementInfo, in elements: [ElementInfo]) -> Bool {
        guard let index = elements.firstIndex(where: { $0.ref == element.ref }) else { return true }
        let next = elements.index(after: index)
        return next >= elements.endIndex || elements[next].depth <= element.depth
    }

    private static func contains(_ rect: FTRect, x: Double, y: Double) -> Bool {
        x >= rect.x && x <= rect.x + rect.width && y >= rect.y && y <= rect.y + rect.height
    }
}
