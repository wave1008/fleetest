// ref で指した要素を「撃つ直前に撮り直して照合する」ための純ロジック。
//
// なぜ要るか(探索で3形とも実機ならぬ Simulator/Emulator 上で決定的に再現した):
//   1. Android の Compose は縦横どちらのスクロール後も a11y ツリーが**古いまま固まる**。
//      ft_snapshot が返す frame はスクロール前のもので、その ref を叩くと**別の行**が発火し、
//      ツールは "tap done" を返す(#row_03 を叩いて selected=row_10 になった)
//   2. Compose iOS は容器の外へ出た行を**フルフレームのまま木に残す**(ghost)。
//      XCUITest ブリッジはそれを座標で叩くので、下部タブバーの上に重なった ghost を叩くと
//      **タブが切り替わる**(ios-inapp-boost は要素起動なので当たる = モードで結果が割れる)
//   3. 上2つはどちらも**沈黙した誤操作**で、後段の検証だけが落ちて原因が遠い
//
// 対策は「ref を信用しない」こと。**ref はスナップショットごとに振り直される**ので、
// 覚えた要素の同一性(identifier → label+型 → 型+frame)で撮り直した木から引き直し、
// 引けなければ撃たずに理由を返す。ghost 判定は ContainerGeometry.isOutsideContainer と共有する
// (MCP 側に別の閾値を置くと DSL と定義が割れる)。

import FTCore

enum RefGuard {

    // MARK: - 共有した幾何(実体は FTCore.TapTargetGeometry / FTCore.OcclusionGeometry)
    //
    // **DSL(StepExecutor)と同じ定義を使う**ために FTCore へ出した。ここは転送だけにして
    // 呼び出し側を書き換えない —— 掃討ゲート(SweepHarnessTests)が「移しても件数が変わらない」
    // ことを実アプリのコーパスで検証する。占有判定(occluder/overlayCovering/isUntappableGhost/
    // stackedRefs/enclosesAnInnerWrapper)の実体は FTCore.OcclusionGeometry。

    static let fullScreenContainerAreaRatio = TapTargetGeometry.fullScreenContainerAreaRatio
    static let interactiveTypes = TapTargetGeometry.interactiveTypes

    static func contains(_ outer: FTRect, _ inner: FTRect) -> Bool {
        TapTargetGeometry.contains(outer, inner)
    }

    static func lineage(of element: ElementInfo, in elements: [ElementInfo]) -> Set<Int> {
        TapTargetGeometry.lineage(of: element, in: elements)
    }

    static func missesItsOwnContent(_ element: ElementInfo, in elements: [ElementInfo],
                                    screen: FTRect) -> ElementInfo? {
        TapTargetGeometry.missesItsOwnContent(element, in: elements, screen: screen)
    }

    static func isClippedSliver(_ element: ElementInfo, screen: FTRect) -> Bool {
        TapTargetGeometry.isClippedSliver(element, screen: screen)
    }

    static func nestedActionCoveringCentre(_ element: ElementInfo,
                                           in elements: [ElementInfo]) -> ElementInfo? {
        TapTargetGeometry.nestedActionCoveringCentre(element, in: elements)
    }

    static func outsideDeclaredScroller(_ element: ElementInfo,
                                        in elements: [ElementInfo], screen: FTRect) -> ElementInfo? {
        TapTargetGeometry.outsideDeclaredScroller(element, in: elements, screen: screen)
    }

    /// 撮り直した木での照合結果
    enum Outcome {
        /// 同じ要素を引き直せた(moved = 前回から動いた距離 pt/px)
        case found(ElementInfo, moved: Double)
        /// 木から消えた
        case gone
        /// スクロール容器の**完全に外**に居る(ghost)。座標を撃つと別の要素に当たる
        case ghost(ElementInfo)
    }

    /// 「動いた」と注記する下限。1px 未満は丸め差なので黙る
    static let movedThreshold: Double = 1.0

    /// 覚えていた要素 `target` を、撮り直した木 `fresh` から引き直す
    static func relocate(_ target: ElementInfo, in fresh: [ElementInfo], screen: FTRect) -> Outcome {
        guard let found = match(target, in: fresh) else { return .gone }
        if isUntappableGhost(found, in: fresh, screen: screen) { return .ghost(found) }
        return .found(found, moved: distance(target.frame, found.frame))
    }

    static func isUntappableGhost(_ element: ElementInfo, in elements: [ElementInfo],
                                  screen: FTRect) -> Bool {
        OcclusionGeometry.isUntappableGhost(element, in: elements, screen: screen)
    }

    static func stackedRefs(_ elements: [ElementInfo]) -> Set<Int> {
        OcclusionGeometry.stackedRefs(elements)
    }

    static let stackedFrameMinimum = OcclusionGeometry.stackedFrameMinimum

    static func overlayCovering(_ element: ElementInfo, in elements: [ElementInfo],
                                screen: FTRect) -> ElementInfo? {
        OcclusionGeometry.overlayCovering(element, in: elements, screen: screen)
    }

    static func occluder(of element: ElementInfo, in elements: [ElementInfo],
                         screen: FTRect) -> ElementInfo? {
        OcclusionGeometry.occluder(of: element, in: elements, screen: screen)
    }

    /// `candidate` が `element` より手前に描かれているか。
    ///
    /// **ブリッジが塗り順(`z`)を申告するなら必ずそれを使う**。ツリー順は描画順の代理として
    /// 使ってきたが、production では裏返る —— Google マップは地図の FAB(ref 81〜86)を
    /// シート(ref 17〜61)より**後**に出すのに、描画はシートが手前。実測では
    /// `#mylocation_button` を無警告でタップして裏の広告を踏み、**Chrome が起動**した。
    ///
    /// `z` を持たないブリッジ(iOS の XCUITest / in-app には描画順を読む API が無い)では
    /// ref 順へ落ちる。**両者が揃っているときだけ z を信じる**のは、
    /// 片方だけ nil の木(打ち切りや別ブリッジの混在)で大小が無意味になるため
    /// 判定の実体は `FTCore.PaintOrder` にある(DSL の `OcclusionSuspicion` と共有。
    /// 別々に持つと、同じ画面で MCP と DSL の遮蔽判定が食い違う)
    static func drawnAbove(_ candidate: ElementInfo, _ element: ElementInfo) -> Bool {
        PaintOrder.drawnAbove(candidate, element)
    }

    static func enclosesAnInnerWrapper(of element: ElementInfo, candidate: ElementInfo,
                                       in elements: [ElementInfo]) -> Bool {
        OcclusionGeometry.enclosesAnInnerWrapper(of: element, candidate: candidate, in: elements)
    }

    /// 同一性の照合。**強い手掛かりから順に**当てて、候補が複数なら最も近い frame を採る。
    /// 型を必ず見るのは、同じラベルの Button と StaticText が並ぶ形(E2E の `#txt_shared_label` /
    /// `#btn_shared_label`)で取り違えないため
    static func match(_ target: ElementInfo, in fresh: [ElementInfo]) -> ElementInfo? {
        if let id = target.identifier, !id.isEmpty {
            if let hit = nearest(to: target, among: fresh.filter { $0.identifier == id }) { return hit }
            // identifier があるのに1つも無い = 消えた。ラベルで拾い直すと**別の要素**を掴む
            return nil
        }
        if let label = target.label, !label.isEmpty {
            let sameLabel = fresh.filter { $0.label == label && $0.type == target.type }
            if let hit = nearest(to: target, among: sameLabel) { return hit }
            return nil
        }
        // id もラベルも無い要素(装飾・容器)。**動いていないことだけ**を根拠に同一とみなす
        return fresh.first { $0.type == target.type && sameFrame($0.frame, target.frame) }
    }

    private static func nearest(to target: ElementInfo,
                                among candidates: [ElementInfo]) -> ElementInfo? {
        candidates.min { distance($0.frame, target.frame) < distance($1.frame, target.frame) }
    }

    private static func sameFrame(_ a: FTRect, _ b: FTRect) -> Bool {
        abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5
            && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    /// frame 中心どうしの距離
    static func distance(_ a: FTRect, _ b: FTRect) -> Double {
        let dx = (a.x + a.width / 2) - (b.x + b.width / 2)
        let dy = (a.y + a.height / 2) - (b.y + b.height / 2)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// 失敗メッセージ用の人が読める識別(`#id` があればそれ、無ければ型とラベル)
    // ゼロ幅文字を落とす理由(visibleLabelsHint と同じ)ごと実体は FTCore 側。describe は
    // tap の警告・goneMessage・遮蔽/ghost の警告が全部通る口なので、ここが最後の砦
    static func describe(_ element: ElementInfo) -> String {
        TapTargetGeometry.describe(element)
    }

    /// **打ち切りも「消えた」の原因になる**(欠陥①と同型): 画面が密になるとブリッジの
    /// 要素上限に押し出され、画面には出ているのに木から落ちる。原因を「画面が変わった」と
    /// 断定すると、そこで探索が止まる
    /// **キーボードが出ているなら、消えた原因の第一候補はキーボード**(木はキーボードの裏の要素を
    /// 落とすことがある)。`keyboardShown` は直近の木の `KeyboardWait.isShown`。「画面が変わった」と
    /// 断定すると、キーボードを閉じれば戻る場面で探索が止まる
    /// **アプリ内のアラートが前面に出ているならそれを名指しする**(`inAppAlert` = 読み直した木の
    /// `AlertTreeScope.frontInAppAlert`。既定値を置かない = 呼び手に決めさせる)。アラートの間は木がその中身だけになるので
    /// 的は「消えた」ように見えるが、閉じれば戻る —— 「画面が変わった」と言うと読み手は撮り直しを1回払ってから気づく(計測)
    static func goneMessage(ref: Int, target: ElementInfo, truncatedCount: Int = 0,
                            keyboardShown: Bool = false, inAppAlert: (alert: ElementInfo, buttons: [String])?) -> String {
        let truncated = truncatedCount > 0
            ? " (or it was pushed out of the tree: \(truncatedCount) element(s) were omitted"
                + " by the snapshot limit)"
            : ""
        if let (alert, buttons) = inAppAlert {
            // 的がそのアラートの中身(入力欄など)なら「アラートのボタンを押せ」は誤誘導 —— 従うと的ごと閉じる。
            // 古い ref が再照合できなかっただけなので、撮り直して新しい ref を使わせる
            if TapTargetGeometry.contains(alert.frame, target.frame) {
                return "[\(ref)] \(describe(target)) is inside \(describe(alert)) but this ref no longer matches it"
                    + " (the alert is still open) — take a fresh ft_snapshot and use the new ref."
                    + " Do not tap the alert's buttons unless you mean to close it."
            }
            let named = buttons.isEmpty ? "" : " (buttons: " + buttons.map { "\"\($0)\"" }.joined(separator: " / ") + ")"
            return "[\(ref)] \(describe(target)) is not reachable right now — \(describe(alert))\(named) is in front"
                + " of the app. Handle it first (ft_tap one of its buttons), then take a fresh ft_snapshot."
        }
        if keyboardShown {
            return "[\(ref)] \(describe(target)) is no longer in the tree — the on-screen keyboard"
                + " is up and may be covering it (or the screen changed after that ft_snapshot)\(truncated)."
                + " Dismiss the keyboard (ft_hide_keyboard) and take a fresh ft_snapshot,"
                + " then use the new ref."
        }
        return "[\(ref)] \(describe(target)) is no longer in the tree — the screen changed after"
            + " that ft_snapshot\(truncated). Take a fresh ft_snapshot and use the new ref."
    }

    /// **撃つ。ただし何に当たったかもしれないかを言う**(拒否から後退した経緯がある)。
    ///
    /// 木の幾何だけでは「実際に描かれているか」を決められない、というのが5形の誤検知で
    /// 示された結論。相手が残像でなく、包含でもなく、それでも描かれていないことがある
    /// (キーボードの下・スクロールアウト)。**キーボードはスナップショットから除外されている**
    /// ので frame すら取れず、原理的に判定材料が足りない。
    ///
    /// 押せる要素を押せなくする害は、誤操作を見逃す害と**別種で、こちらは確実に起きる**。
    /// 情報だけ渡して判断はエージェントに委ねる —— 一覧の行にも印が付いているので、
    /// 「怪しいものを撃った」ことは黙って通り過ぎない
    static func ghostWarning(found: ElementInfo, in elements: [ElementInfo], screen: FTRect) -> String {
        let hit = occluder(of: found, in: elements, screen: screen)
            .map { " (possibly \(describe($0)))" } ?? ""
        return " (warning: \(describe(found)) is reported outside its scroll container, so this"
            + " may have hit whatever is really drawn there\(hit) — verify with ft_screenshot,"
            + " or use ft_scroll_to to bring it into view first)"
    }

    /// **無効な要素を叩こうとしている**ときの警告。木には `disabled` と印字しているのに、
    /// 操作経路は `enabled` を一度も見ておらず、押しても何も起きない要素へ "done" を返していた
    /// (棚卸しで確認。E2E-CMP の契約上「押しても何も起きない」ボタンに対し
    /// tap / press / double_tap の3つとも無警告で成功していた。実アプリでも
    /// Apple マップの経路画面に `#CardButtonTypeShare disabled` がある)。
    ///
    /// **拒否ではなく警告**にする —— 「無効な要素が反応しないこと」を確かめる操作は正当で、
    /// DSL 側にも `enabledIsFalse` がある
    static func disabledWarning(_ element: ElementInfo) -> String {
        guard !element.enabled else { return "" }
        return " (warning: \(describe(element)) is disabled, so this almost certainly did nothing)"
    }

    /// **中心が画面の外にある要素を撃とうとしている**ときの警告。ウィンドウ外のタッチは
    /// hitTest に乗らず黙って落ちる(判定は TapTargetGeometry.offscreenAdvisory = DSL と共有)。
    /// 実測: カレンダーでヘッダ裏へ抜けた `#slot_07`(中心 y=-18)への
    /// ft_tap が無警告の "done" を返し、画面は 1px も変わらなかった
    static func offscreenWarning(_ element: ElementInfo, screen: FTRect) -> String {
        guard let advisory = TapTargetGeometry.offscreenAdvisory(for: element, screen: screen) else {
            return ""
        }
        // 中心が画面の上端より上なら「何も起きない」と言い切らない: iOS はその点がステータスバーへ寄り、
        // OS の scrollsToTop が一覧を先頭へ戻す(実測 9/9 で効いた。座標の経路は同じ点を断る)
        let centreY = element.frame.y + element.frame.height / 2
        if centreY < screen.y - TapTargetGeometry.offscreenCentreTolerance {
            return " (warning: \(describe(element)) — its centre (\(Int(element.frame.x + element.frame.width / 2)),"
                + " \(Int(centreY))) is outside the visible screen, above its top edge, so the element itself is not"
                + " tapped; on iOS the touch can land on the status bar instead, which scrolls a list back to its top"
                + " (the screen may have changed). Bring it into view with ft_scroll_to and re-snapshot)"
        }
        return " (warning: \(describe(element)) — \(advisory);"
            + " bring it into view with ft_scroll_to and re-snapshot)"
    }

    /// **中心がソフトキーボードの下にある要素を撃とうとしている**ときの警告。木からは判定できない
    /// (キーボードはスナップショットの対象外)ので、ブリッジが申告する `keyboardFrame` でだけ言える
    /// (判定は KeyboardOcclusion = DSL と共有。chrome 自身とその部分木には言わない)。
    /// 実測(iOS): キーボード下の候補行 ref タップが警告なしで顔文字キーに当たった
    static func keyboardWarning(_ element: ElementInfo, keyboardOcclusion: KeyboardOcclusion) -> String? {
        guard let advisory = keyboardOcclusion.advisory(for: element) else { return nil }
        return " (warning: \(describe(element)) — \(advisory))"
    }

    /// **木に出ないオーバーレイ・ウィンドウの下にある要素を撃とうとしている**ときの警告。
    /// キーボードと同じ理由でブリッジ申告からしか言えない(判定は `OverlayWindowOcclusion`
    /// = DSL と共有)。実測(実機 Pixel 4a の Chrome): テキスト選択の
    /// フローティングツールバーの下にある段落への ft_tap が無警告の "done" を返し、
    /// 実際には「Select all」に当たってページ全体が選択された
    static func overlayWindowWarning(_ element: ElementInfo,
                                     overlayWindows: OverlayWindowOcclusion) -> String? {
        guard let advisory = overlayWindows.advisory(for: element) else { return nil }
        return " (warning: \(describe(element)) — \(advisory);"
            + " ft_screenshot shows the overlay)"
    }

    /// **画面上端の安全領域の帯の中にある要素を撃とうとしている**ときの警告(判定は
    /// `TapTargetGeometry.topSafeAreaAdvisory` = DSL と共有。ブリッジの申告が `.unknown` なら言わない)
    static func topSafeAreaWarning(_ element: ElementInfo, safeAreaTop: SafeAreaTop, screen: FTRect) -> String? {
        guard let advisory = TapTargetGeometry.topSafeAreaAdvisory(
            for: element, safeAreaTop: safeAreaTop, screen: screen) else { return nil }
        return " (warning: \(describe(element)) — \(advisory);"
            + " ft_scroll_to brings it into view, then re-snapshot)"
    }

    /// keyboard + overlay window + disabled + 安全領域の帯の組(帯は最後 = `TapTargetGeometry.advisory` と同じ並び)。**この順序で4箇所から呼ばれる** ——
    /// 申告由来の2つを先にするのは、木からは判定できず ghost/overlap 側では検知できない
    /// 唯一の警告だから。**`overlayWindows` に既定値を置かない**(呼び忘れをコンパイルで止める)
    /// `suppressKeyboardWarning`: 触らずに打つ操作(焦点の欄への ft_type / ft_clear_input = `typesWithoutTouching`)はキーボードの下でも
    /// 「タップがキーボードに当たる」と言わない。既定値を置かない(呼び手に決めさせる)
    static func preTapWarnings(_ element: ElementInfo, keyboardOcclusion: KeyboardOcclusion,
                               suppressKeyboardWarning: Bool,
                               overlayWindows: OverlayWindowOcclusion,
                               safeAreaTop: SafeAreaTop, screen: FTRect) -> String {
        (suppressKeyboardWarning ? "" : keyboardWarning(element, keyboardOcclusion: keyboardOcclusion) ?? "")
            + (overlayWindowWarning(element, overlayWindows: overlayWindows) ?? "")
            + disabledWarning(element)
            + (topSafeAreaWarning(element, safeAreaTop: safeAreaTop, screen: screen) ?? "")
    }

    /// **申告されたスクロール容器の外へ送り出された要素を撃とうとしている**ときの警告
    /// (判定は TapTargetGeometry.outsideDeclaredScroller)。`ghostWarning` と同じ事象だが、
    /// あちらの入口は容器の**推測**(`ContainerGeometry.isOutsideContainer`)なので、申告のある
    /// UIKit/SwiftUI の木では nil に落ちて1件も捕まえていなかった。
    ///
    /// 実測(Apple マップ): カードを送って `#MUScrollableStackView` (0,72 402x802) の
    /// 上へ抜けた `link "ウィキペディア"` (16,-2 85x18) への ft_tap が無警告の "done" を返し、
    /// 実際には中心 (58,7) = ステータスバーに当たってカードが先頭へ飛んだ
    static func scrolledOutWarning(_ element: ElementInfo, in elements: [ElementInfo],
                                   screen: FTRect) -> String {
        guard let scroller = outsideDeclaredScroller(element, in: elements, screen: screen)
        else { return "" }
        return " (warning: \(describe(element)) is reported entirely outside \(describe(scroller)),"
            + " which is the scroll container it belongs to — it is a leftover from scrolling,"
            + " not what you see. Bring it into view with ft_scroll_to and re-snapshot)"
    }

    /// **判定は `TapTargetGeometry.advisoryKind` の1箇所だけ**(DSL の `occlusionAdvisory` と共有)。
    /// ここは kind を MCP の文言(要素を名指しし、ft_screenshot / ft_scroll_to という MCP の
    /// ツール名で逃げ道を書く)へ写すだけ —— 順序・当たり判定を書き直さない
    /// `operation` = 文言の操作名("tap" / "double tap" / "drag" / "type" 等。既定値を置かない = 呼び手に決めさせる)
    static func overlapWarning(found: ElementInfo, in elements: [ElementInfo], screen: FTRect,
                               isAndroid: Bool, operation: String) -> String {
        guard let kind = TapTargetGeometry.advisoryKind(for: found, in: elements, screen: screen)
        else { return "" }
        switch kind {
        case .zeroFrame:
            // **DSL にだけあり MCP のタップ時には出ていなかった形**(合流済み)
            return " (warning: \(describe(found))'s reported frame has zero width/height,"
                + " so the \(operation) may land on whatever is at that point — verify with ft_screenshot)"
        case .offscreen:
            // 画面外の中心は「何にも当たらない」= 遮蔽・中身外しより強い事実なので先に言う
            return offscreenWarning(found, screen: screen)
        case .scrolledOut:
            // **容器の外**: これが真なら frame そのものが今の描画位置ではないので、
            // 以下の遮蔽・中身外しはその古い frame を前提にした話になり、名指しが嘘になる
            return scrolledOutWarning(found, in: elements, screen: screen)
        case .overlayCovering(let over):
            return " (warning: \(describe(over)) is drawn over the center of \(describe(found)),"
                + " so this may have hit \(describe(over)) instead — verify with ft_screenshot,"
                + " or scroll the element clear of the overlay first)"
        case .missedContent(let inner):
            return " (warning: \(describe(found)) does not report itself as interactive and its center is not over any"
                + " of its own content, so this \(operation) may have gone to whatever is behind it."
                + " If nothing happened, target the content instead, e.g. \(describe(inner)))"
        case .nestedAction(let nested):
            // **子孫が中心を横取りしている**。`overlayCovering` は子孫を除外するので届かない
            // (Apple マップの検索候補で実害。TapTargetGeometry の解説を参照)
            return " (warning: \(describe(nested)) sits inside \(describe(found)) and covers its"
                + " center, so this may have triggered \(describe(nested)) instead of"
                + " \(describe(found)) — verify with ft_screenshot, and target the part you"
                + " actually want)"
        case .stacked:
            // **「完全一致」と断定しない**: 判定は原点だけが同じで大きさが違う
            // クランプも見るようになった(OcclusionGeometry.originClampedRefs)。DSL 側の
            // 同じ文面(TapTargetGeometry.occlusionAdvisory)と揃える
            return " (warning: \(describe(found)) is stacked on the same spot as other elements,"
                + " so at most one of them is really drawn there — the rest are clamped"
                + " leftovers. Bring it into view with ft_scroll_to and re-snapshot)"
        case .clippedByContainer(let container):
            // **判定は TapTargetGeometry.clippedAtContainerEdge の1箇所**(実測は同関数の doc)。
            // ブリッジは frame を容器で切ってから送るので overflow の座標は残らず、
            // 縁の一致 + 高さ不足の shortfall witness でしか拾えない
            let edge = TapTargetGeometry.isClippedAtBottomEdge(found, container: container)
                ? "bottom" : "top"
            let h = Int(found.frame.height.rounded())
            if isAndroid {
                return " (note: \(describe(found)) is cut off at the \(edge) edge of"
                    + " \(describe(container)), only \(h) of its height is drawn, but on Android"
                    + " the visible part is normally still tappable at its visible centre, so this"
                    + " most likely hit \(describe(found)) — scroll it fully into view with"
                    + " ft_scroll_to if the result looks wrong)"
            }
            return " (warning: \(describe(found)) is cut off at the \(edge) edge of"
                + " \(describe(container)), only \(h) of its height is drawn, so this may have hit"
                + " whatever is drawn there instead — scroll it fully into view with"
                + " ft_scroll_to, and verify with ft_screenshot)"
        case .sliver:
            // **DSL にだけあり MCP のタップ時には出ていなかった形**(合流済み)
            return " (warning: \(describe(found)) is clipped to a thin sliver at the edge of its"
                + " container, so it is narrower than it looks and the tap may miss —"
                + " verify with ft_screenshot)"
        }
    }

    /// `unit` は木の座標の単位(iOS=pt / Android=px)。呼び手が `isAndroid` から渡す(既定は Android の px)
    static func movedNote(found: ElementInfo, moved: Double, cause: String, unit: String = "px") -> String {
        " (\(describe(found)) had moved \(Int(moved.rounded()))\(unit) since the snapshot;"
            + " retargeted to where it is now\(cause))"
    }

    /// **同一 identifier で再ターゲットしたら、ラベルが変わっていないかも見る**(実アプリ監査で発覚)。
    /// `match(_:in:)` は identifier があればそれだけで引き直すので、検索候補が
    /// 更新された画面では**同じ id・違う行**を掴むことがある。実測: 「立川駅、最近表示した項目」を
    /// 狙ったタップが「立川駅 南口、立川市」に化けたが、位置の話(movedNote)しかしていなかった。
    /// **動いていなくても出す**(ラベルだけ変わって位置が同じ形も同じ危険)
    static func labelChangeNote(old: String?, new: String?) -> String? {
        guard let old = old?.trimmingCharacters(in: .whitespacesAndNewlines), !old.isEmpty,
              let new = new?.trimmingCharacters(in: .whitespacesAndNewlines), !new.isEmpty,
              old != new else { return nil }
        return "; caution: its label has changed from"
            + " \"\(SnapshotRenderer.truncate(old, SnapshotRenderer.labelDisplayLimit))\" to"
            + " \"\(SnapshotRenderer.truncate(new, SnapshotRenderer.labelDisplayLimit))\""
            + " since the snapshot — the list may have refreshed and this can be a different row;"
            + " verify the outcome"
    }

    /// 付け替えの判定(`verifiedRef` / `verifiedElement` / scrollFrame の ref が**全部ここ1つ**を通す。ghost も同じ)。
    /// 件数は「採った木」と「今の木」を別々に持つ(断りの文が事実どおりの数を言う)
    enum RetargetVerdict: Equatable {
        case proceed
        /// 採った行とは別の行の部品へ付け替わる。撃たない
        case differentRow(Matcher, taken: Int, now: Int)
        /// 同じ id が複数あり動いたが、親に id もラベルも無く行を区別できない。**断らず注記だけ**(断ると同じ行が少し動くだけで全部断る)
        case rowsIndistinct(Matcher, taken: Int, now: Int)
        /// id の無いボタン系が、同じラベル・型の仲間の間隔の半分以上動き、行も区別できない = 隣の行の同じ部品かもしれない。撃たない
        case travelledPastNeighbour(taken: Int, now: Int)
        /// id の無いボタン系が元の枠を離れ、周りは1つも同じだけ動いていない = スクロールではなく、別の場所に同じ見た目の部品が出た。撃たない
        case movedAlone
        /// このセッションの操作の後でラベルが変わり、位置・周り・画面の顔ぶれも変わった = 別の画面の同じ id。撃たない
        case labelChangedElsewhere
        /// このセッションの操作の後で、残った id が全部同じ量だけ動き、同じ数以上の新しい id が現れた = 遷移の途中。撃たない
        case screenTransition(shifted: Int, arrivals: Int)
    }

    /// 付け替えが何で同一視したか(件数の数え方と文言を決める)
    enum Matcher: Equatable { case identifier, label }

    /// **「同じ行か」は親の行の顔ぶれ(id・ラベルの集合)の変化だけで決める**。動いた距離では決めない
    /// (同じ行が数 pt〜数十 pt 動くだけで断っていた。親ごと動くので顔ぶれは変わらない)。
    /// 同じ id(id が無ければ同じラベル・型)の件数は採った木と今の木の**多いほう**(今の木で1件だけ残る形 = 別の行へ付け替わる最悪の形を通さない)。
    /// 親の顔ぶれが両方空(行を区別できない)なら動いたときだけ `rowsIndistinct`。採った木が無い(`taken` 空)も同じ。
    ///
    /// **id の無い対象(ラベルで引き直した要素)も行の顔ぶれを見る**(「削除」ボタンが別の行の「削除」へ付け替わって別の行が消えた)。
    /// 件数が1件ずつ(採った木も今の木も1件)でも、別の行へ動いた形は起きる(行を閉じて別の行を開くと「削除」は常に1件)ので、
    /// **ボタン系(`interactiveTypes`)が動き、かつ周りの顔ぶれが変わったときは件数に関わらず断る**。動かない・顔ぶれが同じなら通す
    /// (周りのラベルだけ変わる形で誤って断らない)。顔ぶれが区別できない(両方空)形は、同じラベル・型の仲間が複数あり
    /// **動いた距離が仲間との最短間隔の半分以上**のときだけ断る(半分未満なら最も近い候補は元の要素と取り違えようがない)。
    /// 尽きたとき(撃たなかったとき)は断りの文が新しい ft_snapshot の ref を使わせる。
    /// ラベル変化は**このセッションの操作の後**に限り、位置が動かず・親の顔ぶれが同じで・画面の識別子の過半が残っているなら
    /// 同じ部品の状態変化(押すと「開始」→「停止」になるトグル)として通す
    static func retargetVerdict(target: ElementInfo, found: ElementInfo, in fresh: [ElementInfo],
                                taken: [ElementInfo], ownActionSince: Bool) -> RetargetVerdict {
        let moved = distance(target.frame, found.frame)
        let rowBefore = taken.isEmpty ? nil : enclosingRow(of: target, in: taken)
        let rowAfter = enclosingRow(of: found, in: fresh)
        let sameRow = rowBefore.map { $0 == rowAfter }
        let indistinct = moved >= movedThreshold
            && (sameRow == nil || (rowBefore?.isEmpty == true && rowAfter.isEmpty))
        if let id = target.identifier, !id.isEmpty {
            let same: ([ElementInfo]) -> Int = { tree in
                tree.filter { $0.identifier == id && $0.type == found.type }.count
            }
            let (nowCount, takenCount) = (same(fresh), same(taken))
            if max(nowCount, takenCount) >= 2 {
                if sameRow == false { return .differentRow(.identifier, taken: takenCount, now: nowCount) }
                if indistinct { return .rowsIndistinct(.identifier, taken: takenCount, now: nowCount) }
            }
        } else if let label = target.label, !label.isEmpty {
            let sameKind: ([ElementInfo]) -> [ElementInfo] = { tree in
                tree.filter { $0.label == label && $0.type == found.type }
            }
            let (nowCount, takenCount) = (sameKind(fresh).count, sameKind(taken).count)
            let buttonLike = TapTargetGeometry.interactiveTypes.contains(found.type)
            if buttonLike, moved >= movedThreshold, sameRow == false {
                return .differentRow(.label, taken: takenCount, now: nowCount)
            }
            if buttonLike, indistinct {
                // 仲間との最短間隔(採った木があれば動く前の並び。ref は木ごとの番号なので自分の木の中でだけ除く)
                let others = taken.isEmpty
                    ? sameKind(fresh).filter { $0.ref != found.ref }
                    : sameKind(taken).filter { $0.ref != target.ref }
                if let pitch = others.map({ distance($0.frame, target.frame) }).min(), moved * 2 >= pitch {
                    return .travelledPastNeighbour(taken: takenCount, now: nowCount)
                }
                if movedAlone(target, found, taken: taken, fresh: fresh) { return .movedAlone }
                // 仲間が居ない・近くない: 断る根拠は無い(スクロールで動いただけかもしれない)。注記だけ
                return .rowsIndistinct(.label, taken: takenCount, now: nowCount)
            }
        }
        if ownActionSince, moved >= movedThreshold,
           let t = transitionShape(target, found, taken: taken, fresh: fresh) {
            return .screenTransition(shifted: t.shifted, arrivals: t.arrivals)
        }
        if ownActionSince, labelChangeNote(old: target.label, new: found.label) != nil {
            let sameSpot = moved < movedThreshold && sameRow == true
                && identifierShare(of: taken, keptIn: fresh) >= sameScreenIdentifierShare
            if !sameSpot { return .labelChangedElsewhere }
        }
        return .proceed
    }

    /// 遷移の途中の形: 採った木と今の木の両方に1件ずつある id(`target` 以外)が3件以上あり、**全部**が `target` と同じ量だけ動き、
    /// 今の木にだけある id がその件数以上ある(新しい画面の要素が出揃っている)。
    /// 短いスクロールは新しい id が数行しか出ないので「新しい id ≥ 動いた件数」に届かない。尽きたとき(届いた)は撃たない側
    /// (断っても失うのは撮り直し1回。撃つと新しい画面の別の要素を押す)。閾値の3は「全兄弟が揃った」を偶然と区別する下限で実測の裏づけは無い
    static func transitionShape(_ target: ElementInfo, _ found: ElementInfo,
                                taken: [ElementInfo], fresh: [ElementInfo]) -> (shifted: Int, arrivals: Int)? {
        func unique(_ tree: [ElementInfo], excluding own: ElementInfo) -> [String: ElementInfo] {
            let ids = tree.filter { $0.ref != own.ref }.compactMap { e -> (String, ElementInfo)? in
                guard let id = e.identifier, !id.isEmpty, id != own.identifier else { return nil }
                return (id, e)
            }
            return Dictionary(grouping: ids, by: \.0).compactMapValues { $0.count == 1 ? $0[0].1 : nil }
        }
        let before = unique(taken, excluding: target), after = unique(fresh, excluding: found)
        let pairs = before.compactMap { key, old in after[key].map { (old, $0) } }
        guard pairs.count >= 3 else { return nil }
        let (dx, dy) = (found.frame.x - target.frame.x, found.frame.y - target.frame.y)
        guard pairs.allSatisfy({ old, now in
            abs((now.frame.x - old.frame.x) - dx) < 2 && abs((now.frame.y - old.frame.y) - dy) < 2
        }) else { return nil }
        let takenIDs = Set(taken.compactMap { $0.identifier }.filter { !$0.isEmpty })
        let arrivals = Set(fresh.compactMap { $0.identifier }.filter { !$0.isEmpty }).subtracting(takenIDs).count
        return arrivals >= pairs.count ? (pairs.count, arrivals) : nil
    }

    /// 同じ画面とみなす識別子の残存割合の下限。**過半**: トグルの押下は識別子を足し引きしても大半が残り、
    /// 画面の入れ替え(入力画面 → ホーム)は共通の枠(ナビ・タブ)の分しか残らない。実測の裏づけは無い目安で、尽きたときは断る側(撃たない)
    static let sameScreenIdentifierShare = 0.5

    private static func identifierShare(of taken: [ElementInfo], keptIn fresh: [ElementInfo]) -> Double {
        let before = Set(taken.compactMap { $0.identifier }.filter { !$0.isEmpty })
        guard !before.isEmpty else { return 0 }
        let after = Set(fresh.compactMap { $0.identifier }.filter { !$0.isEmpty })
        return Double(before.intersection(after).count) / Double(before.count)
    }

    /// 自分の枠の中に収まる、より深い要素(子孫)。**行の顔ぶれに数えない**: CMP のボタンは子に同じ文字の staticText を出すので、
    /// 押してラベルが変わると「周りが変わった」と読んで同じトグルの2回目を断っていた
    private static func isDescendant(_ candidate: ElementInfo, of element: ElementInfo) -> Bool {
        candidate.depth > element.depth && TapTargetGeometry.contains(element.frame, candidate.frame)
    }

    /// 要素の中心を含む他の要素の id とラベル(値は見ない = トグルの状態の変化を別の行と呼ばない)
    private static func enclosingRow(of element: ElementInfo, in tree: [ElementInfo]) -> Set<String> {
        let x = element.frame.x + element.frame.width / 2, y = element.frame.y + element.frame.height / 2
        return Set(tree.filter {
            $0.ref != element.ref && $0.identifier != element.identifier
                && !isDescendant($0, of: element)
                && x >= $0.frame.x && x <= $0.frame.x + $0.frame.width
                && y >= $0.frame.y && y <= $0.frame.y + $0.frame.height
        }.map { "\($0.identifier ?? "")|\($0.label ?? "")" })
    }

    /// 付け替えの結果を呼び手が使える形にする(断りは throw する文言・注記は撃った後の応答へ足す文)。**全呼び手が同じ口**
    static func retargetOutcome(ref: Int, target: ElementInfo, found: ElementInfo, in fresh: [ElementInfo],
                                taken: [ElementInfo], ownActionSince: Bool) -> (refusal: String?, note: String) {
        let labelNote = labelChangeNote(old: target.label, new: found.label) ?? ""
        switch retargetVerdict(target: target, found: found, in: fresh, taken: taken, ownActionSince: ownActionSince) {
        case .proceed:
            return (nil, labelNote)
        case .differentRow(let matcher, let takenCount, let nowCount):
            return (ambiguousRetargetRefusal(ref: ref, old: target, matcher: matcher, taken: takenCount, now: nowCount), "")
        case .travelledPastNeighbour(let takenCount, let nowCount):
            return (travelledPastNeighbourRefusal(ref: ref, old: target, taken: takenCount, now: nowCount), "")
        case .movedAlone:
            return (movedAloneRefusal(ref: ref, old: target), "")
        case .rowsIndistinct(let matcher, let takenCount, let nowCount):
            return (nil, " (note: \(describe(target)) matched \(takenCount) element(s) with the same \(matcher == .identifier ? "id" : "label") when snapshotted and \(nowCount) now, and its row cannot be told"
                + " apart (no id or label around it), so this may be the same part of another row — verify the outcome)" + labelNote)
        case .labelChangedElsewhere:
            return (labelChangedAfterOwnActionRefusal(ref: ref, old: target, new: found), "")
        case .screenTransition(let shifted, let arrivals):
            return ("refusing [\(ref)]: it was taken before your own later actions, and since then all \(shifted) other element(s) with an id"
                + " shifted by the same amount as \(describe(target)) while \(arrivals) new id(s) appeared — the screen is most likely"
                + " mid-transition, so the element it now matches may belong to the next screen. Nothing was sent."
                + " Take a fresh ft_snapshot (after the transition settles; waitFor on the next screen) and use its ref", "")
        }
    }

    /// 件数は**採った木と今の木で別々に言う**(今の木の件数だけ言うと、採った木では複数あった事実が消える。逆も同じ)
    static func ambiguousRetargetRefusal(ref: Int, old: ElementInfo, matcher: Matcher, taken: Int, now: Int) -> String {
        let key = matcher == .identifier ? "id" : "label"
        let peers = matcher == .identifier
            ? "\(taken) element(s) with the same id when snapshotted, \(now) now"
            : "\(taken) element(s) with the same label and type when snapshotted, \(now) now"
        return "refusing [\(ref)]: \(describe(old)) matched \(peers); the one nearest to where it was"
            + " snapshotted sits in a different row now (the elements around it changed), so this can be the same-looking part of another row"
            + " (same \(key)). Nothing was sent."
            + " Take a fresh ft_snapshot and use its ref (or target the row by a label / a unique selector)"
    }

    static func movedAloneRefusal(ref: Int, old: ElementInfo) -> String {
        "refusing [\(ref)]: \(describe(old)) has no id, and the element it now matches left its old position while nothing"
            + " around it moved the same way, so this is not a scroll — it can be the same-looking part of another row. Nothing was sent."
            + " Take a fresh ft_snapshot and use its ref (or target the row by a label / a unique selector)"
    }

    /// `target` の枠を離れ(新旧の枠が重ならない)、周りの要素が1つも同じだけ動いていないか。スクロールや上の要素の伸縮なら周りが揃って動く。
    /// 周りは id か「ラベル + 型」が両方の木で1件の要素。**自分の枠の中(子の文字)は数えない**(一緒に動くので常に「揃った」になる)。
    /// 比べられる相手が2件に満たないときは判定しない = false(`movedTogether` と同じ下限)
    static func movedAlone(_ target: ElementInfo, _ found: ElementInfo, taken: [ElementInfo], fresh: [ElementInfo]) -> Bool {
        func overlaps(_ a: FTRect, _ b: FTRect) -> Bool {
            a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
        }
        guard !overlaps(target.frame, found.frame) else { return false }
        func unique(_ tree: [ElementInfo], excluding own: ElementInfo) -> [String: ElementInfo] {
            let keyed = tree.filter { !contains(own.frame, $0.frame) }.compactMap { element -> (String, ElementInfo)? in
                if let id = element.identifier, !id.isEmpty { return ("#\(id)", element) }
                if let label = element.label, !label.isEmpty { return ("\(element.type)|\(label)", element) }
                return nil
            }
            return Dictionary(grouping: keyed, by: \.0).compactMapValues { $0.count == 1 ? $0[0].1 : nil }
        }
        let before = unique(taken, excluding: target), after = unique(fresh, excluding: found)
        let pairs = before.compactMap { key, old in after[key].map { (old, $0) } }
        guard pairs.count >= 2 else { return false }
        let (dx, dy) = (found.frame.x - target.frame.x, found.frame.y - target.frame.y)
        return !pairs.contains { old, now in
            abs((now.frame.x - old.frame.x) - dx) < 2 && abs((now.frame.y - old.frame.y) - dy) < 2
        }
    }

    static func travelledPastNeighbourRefusal(ref: Int, old: ElementInfo, taken: Int, now: Int) -> String {
        "refusing [\(ref)]: \(describe(old)) has no id, and the element it now matches moved at least half the distance to"
            + " its nearest look-alike (same label and type; \(taken) element(s) when snapshotted, \(now) now) while nothing around it tells the rows apart,"
            + " so this can be the same-looking part of a neighbouring row. Nothing was sent."
            + " Take a fresh ft_snapshot and use its ref (or target the row by a label / a unique selector)"
    }

    /// 古い ref が、このセッションの操作の後でラベルの違う要素に付け替わったときの断り(撃っていない)
    static func labelChangedAfterOwnActionRefusal(ref: Int, old: ElementInfo, new: ElementInfo) -> String {
        "refusing [\(ref)]: it was taken before your own later actions, and the element it now matches,"
            + " \(describe(new)), reads \"\(SnapshotRenderer.truncate(new.label ?? "", SnapshotRenderer.labelDisplayLimit))\""
            + " instead of \"\(SnapshotRenderer.truncate(old.label ?? "", SnapshotRenderer.labelDisplayLimit))\""
            + " — and it also moved or sits among different elements, so the screen likely changed and this is probably a different element."
            + " Nothing was sent."
            + " Take a fresh ft_snapshot and use its ref"
    }

    /// **原因は断定できないが、範囲は言える**: 同じ分だけ動いた要素が他にもあるなら
    /// スクロール等の画面全体の移動、その要素だけならレイアウト変化。
    /// 「なぜ動いたか」の手掛かりが欲しいという要望への、嘘をつかない答え
    /// `ownActionSince`: このセッションの操作が snapshot の後にあった。画面遷移の最中も兄弟がそろって動くので、
    /// スクロールと断定しない(遷移中の古い木で別の画面の行を押した実例)
    static func movedTogether(_ target: ElementInfo, _ found: ElementInfo,
                              before: [ElementInfo], after: [ElementInfo],
                              ownActionSince: Bool = false) -> String {
        let dy = found.frame.y - target.frame.y
        let dx = found.frame.x - target.frame.x
        // **比べる相手は同じ深さの兄弟だけ**。画面全体で数えると、固定ヘッダやタブバーのような
        // 動かない chrome が多数派になり、スクロールでも「動いていない」と誤答する
        // (実測: リストが 295px スクロールしたのに、動かない要素 13 対 動いた要素 7 で誤判定)
        var samePairs = 0
        var otherPairs = 0
        for old in before where old.ref != target.ref && old.depth == target.depth {
            guard let id = old.identifier, !id.isEmpty,
                  let now = after.first(where: { $0.identifier == id }) else { continue }
            otherPairs += 1
            if abs((now.frame.y - old.frame.y) - dy) < 2, abs((now.frame.x - old.frame.x) - dx) < 2 {
                samePairs += 1
            }
        }
        guard otherPairs >= 2 else { return "" }
        // 兄弟の過半が同じ分だけ動いた = 面ごと動いた(スクロール等)
        if samePairs * 2 >= otherPairs, ownActionSince {
            return "; \(samePairs) of \(otherPairs) siblings shifted by the same amount after your own action —"
                + " that can be a screen transition still animating (this ref may now be a different screen's element),"
                + " not only a scroll; take a fresh ft_snapshot and verify the outcome"
        }
        return samePairs * 2 >= otherPairs
            ? "; \(samePairs) of \(otherPairs) siblings shifted by the same amount,"
                + " so the container scrolled rather than this element alone"
            : "; its siblings did not shift, so the layout changed around it"
    }
}
