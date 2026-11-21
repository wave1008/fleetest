// MCPServer+Snapshot.swift
// snapshot の取得と ref 世代管理・snapshotAfter(ft_scroll_to は +ScrollTools)。本体は MCPServer.swift(instance 状態はそちらに置く)

import Foundation
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore

extension MCPServer {

    /// 木を撮り直す。**MCP は必ずキャッシュを捨てて撮る**(driver が対応していれば)。
    ///
    /// Android の a11y ノードはキャッシュ供給で、**Compose のスクロール後は木が古いまま固まる**
    /// (決定的に再現。撮り直しても数分待っても直らない)。ブリッジ側の既定が
    /// 「WebView 内だけ refresh」なのは**シナリオ実行**の実測(全ノード refresh で
    /// snapshot +65ms・E2E-Android の sum +43%)に基づくもので、MCP はエージェントが
    /// 1手ずつ撃つ経路なので往復のほうが桁で大きく、この上乗せは見えない。
    /// **常時オンにする**(「ジェスチャの後だけ」のフラグ運用は、フラグを立て忘れたツールが
    /// 1つでもあると黙って古い木に戻る)。
    ///
    /// 取得直後に `adoptSnapshot` を通す — ブリッジ由来の native ref をセッション ref へ
    /// 振り直すのはここが唯一の入口(waitFor 経路だけ例外。呼び出し側で個別に通す)
    func freshSnapshot(_ driver: AppDriver, args: [String: Any]) async throws
        -> SnapshotResponse {
        // `maxElements` は**この1回だけ**の上限(ブリッジの `?max=`)。既定へ戻す必要は無い ——
        // ドライバ側が1回で消費する契約なので、次の呼び出しは黙って 120 に戻る
        if let requested = try Self.intArgument(args, "maxElements") {
            driver.raiseElementLimitOnNextSnapshot(requested)
            return adoptSnapshot(try await driver.snapshot(bypassingCache: driver.supportsCacheBypass),
                                 args: args)
        }
        let key = Self.sessionKey(args)
        // ラッチ後は**最初から**天井で撮る(2枚払うのはラッチした1回だけ。DSL の
        // `retakenAtElementLimitCeiling` と同じ設計)
        if webPageCeilingLatched.contains(key) {
            driver.raiseElementLimitOnNextSnapshot(BridgeAPI.maxSnapshotElementsCeiling)
        }
        let native = try await driver.snapshot(bypassingCache: driver.supportsCacheBypass)
        guard !webPageCeilingLatched.contains(key), Self.needsWebPageCeiling(native) else {
            return adoptSnapshot(native, args: args)
        }
        webPageCeilingLatched.insert(key)
        driver.raiseElementLimitOnNextSnapshot(BridgeAPI.maxSnapshotElementsCeiling)
        // **捨てる木は adopt しない**: adopt は ref 世代を進めるので、読み手に渡さない木で
        // 番号を飛ばすと「さっきの ref がもう無い」を自分で増やすことになる
        let full = try await driver.snapshot(bypassingCache: driver.supportsCacheBypass)
        return adoptSnapshot(full, args: args)
    }

    /// 出力を短くする逃げ道の案内。**効くものだけを出す**。
    ///
    /// `interactiveOnly` は「レイアウト専用の行」を隠す道具なので、**そういう行が1つも無い画面では
    /// 1バイトも減らない** —— 実測(Yahoo 天気トップ)で 4,028B → 4,028B。要素がほぼ全部 `link` の
    /// web ページはこの形になる。効かない逃げ道を出すのは逃げ道が無いことより悪い
    /// (読み手はそれを試して1往復を捨てる)ので、消える行数を数えてから勧める。
    /// `maxElements` は常に効く(自分で上限を決め直せる)ので無条件
    static func shorteningAdvice(_ snapshot: SnapshotResponse,
                                 cache: SnapshotAnnotationCache) -> String {
        let hidden = SnapshotRenderer.hiddenByInteractiveOnlyCount(
            snapshot, flagging: cache.ghostFlags(snapshot))
        let interactive = hidden > 0
            ? " Pass interactiveOnly: true to drop \(hidden) layout-only line(s), or" : ""
        return interactive + " pass maxElements to set your own limit."
    }

    /// 待ちのポーリングが毎回かける要素上限(`Self.waitFor` の `elementLimit`)。
    /// **明示指定 > ラッチ > 既定(nil)** —— `freshSnapshot` の優先順と同じにする
    func pollElementLimit(_ args: [String: Any]) throws -> Int? {
        if let requested = try Self.intArgument(args, "maxElements") { return requested }
        return webPageCeilingLatched.contains(Self.sessionKey(args))
            ? BridgeAPI.maxSnapshotElementsCeiling : nil
    }

    /// **切り詰められた web ページなら、言われる前に天井で撮り直す**
    /// (1セッションで 89 件と 72 件を落とされた実績がある)。
    ///
    /// DSL には既に同じ撮り直し(`StepExecutor.retakenAtElementLimitCeiling`)がある一方、
    /// **MCP は別経路なので届いていなかった** —— 注記で「maxElements を上げろ」と案内するだけで、
    /// 読み手は必ず1往復を払い、注記を見落とせば**実在する行を存在しないものとして扱う**。
    ///
    /// **native の密な画面には広げない**。web だけを対象にする根拠は間引きの規則そのもので
    /// (`BridgeAPI.maxSnapshotElementsCeiling` の doc)、web ページは広告リンク等の tier0 が
    /// 枠を埋め、捨てられるのは **tier1 = ラベル付きの本文** = 読み手が欲しい行そのものになる。
    /// native のリストは操作可能な要素が優先的に残るので、同じ被害にはならない。
    /// 既に天井で読まれた木なら撮り直しても同じ木が返るだけなので撮らない。
    ///
    /// **「web ページか」の判定は `TreeCoverage.holdsWebContent` に委ねる**。
    /// 単純に `type == "webView"` だけを見ると、**Android Chrome では1件も発火しない**
    /// (あちらの木に webView 要素は無い)。固定コーパスに Android のブラウザが7枚あるのに
    /// 当てずに入れると、Yahoo 天気で 81 件が脱落する
    static func needsWebPageCeiling(_ snapshot: SnapshotResponse) -> Bool {
        snapshot.truncatedCount > 0 && !SnapshotTruncation.isAtCeiling(snapshot)
            && TreeCoverage.holdsWebContent(in: snapshot)
    }

    /// ref 同一性の比較キー。(ref, type, identifier, label) — 値/frame/focused の変化では
    /// 世代を進めない(adoptSnapshot 参照)ので、この4つだけを見る
    private struct RefIdentity: Hashable {
        let ref: Int
        let type: String
        let identifier: String?
        let label: String?
    }

    private static func identity(_ element: ElementInfo, base: Int) -> RefIdentity {
        RefIdentity(ref: element.ref - base, type: element.type,
                   identifier: element.identifier, label: element.label)
    }

    /// `element` の ref だけ差し替えたコピー(ElementInfo は struct。他フィールドは素通し)
    /// **複写して ref だけ差し替える**(欄を1つずつ並べて作り直さない)。作り直していた頃は後から足した欄
    /// (`inOverlayWindow`・`axClass`・`scrollActions`)を落とし、2世代目以降の木では手前の窓の中身が
    /// 「手前の窓に覆われている」と誤って警告された(XCUITest の上部バナーの閉じるボタンで実測)
    static func withRef(_ element: ElementInfo, _ ref: Int) -> ElementInfo {
        var copy = element
        copy.ref = ref
        return copy
    }

    /// `snapshot.elements` の ref に一律 `base` を足したコピー。offscreen の ref は触らない
    /// (ブリッジは常に 0 を送るスクロールヒントで、要素解決には使われない — BridgeDTO 参照)
    private static func remapped(_ snapshot: SnapshotResponse, base: Int) -> SnapshotResponse {
        guard base != 0 else { return snapshot }
        var copy = snapshot
        copy.elements = snapshot.elements.map { withRef($0, $0.ref + base) }
        return copy
    }

    /// **ref の世代管理の本体**。ブリッジから来た native な snapshot を受け取り、セッション内で
    /// 一意な ref を持つ snapshot へ変換して返す。ブリッジは撮るたびに ref を振り直すので、
    /// 何もしないと「1つ前の木」より前の snapshot の ref を撃たれたとき、たまたま同じ番号を
    /// 持つ別要素へ黙って当たる(冒頭のコメント参照)。
    ///
    /// **同一性が変わらなければ base を使い回す**: 画面が動いていないのに ref を変えると、
    /// 撮り直すたびに番号が変わってエージェントを混乱させる。ラベルが1つでも変われば
    /// (時計等)世代は進むが、それ自体は無害 —— stale 判定は「受領時点で最新だったか」で行う
    /// (resolveSessionRef 参照)ので、無関係な世代の増加が誤警告を増やすことはない。
    /// **最初の世代は base 0**(= ブリッジが返す生の ref とビット単位で同じ)なので、世代が1本の間は
    /// 応答がそのまま一致する。
    func adoptSnapshot(_ native: SnapshotResponse, args: [String: Any]) -> SnapshotResponse {
        let key = Self.sessionKey(args)
        if var generations = refGenerations[key], let last = generations.last {
            let nativeIdentity = Set(native.elements.map { Self.identity($0, base: 0) })
            let lastIdentity = Set(last.snapshot.elements.map { Self.identity($0, base: last.base) })
            // **アプリが同じであることも要求する**(レビュー指摘)。`identity` は
            // frame を見ないので、**兄弟アプリの同じ画面は「同じ木」に見える**。ここで
            // 使い回すと世代が**新しいアプリの sessionBundleID で上書き**され、
            // `refFromAnotherAppMessage` の比較が B vs B になって**2回目の試行で素通り**する
            // (1回目は断るのに、同じ呼び出しをもう一度撃つと通る = 最悪の形)
            if nativeIdentity == lastIdentity,
               last.snapshot.sessionBundleID == native.sessionBundleID {
                // 同じ木 — base を使い回し、最新世代の内容だけ最新化する(frame/value/focused 等)。
                // **actionCount は最初に世代を作ったときの値を保つ**(この呼び出しが記録した
                // 操作より前の値のまま = 「このスナップショットが撮られた時点」の定義を保つ)
                let remapped = Self.remapped(native, base: last.base)
                generations[generations.count - 1] = (base: last.base, snapshot: remapped,
                                                       actionCount: last.actionCount,
                                                       followsOwnAction: last.followsOwnAction,
                                                       delivered: last.delivered)
                refGenerations[key] = generations
                lastSnapshots[key] = remapped
                launchBaselineStale.remove(key)
                return remapped
            }
        }
        let base = nextRefBase
        let remapped = Self.remapped(native, base: base)
        var generations = refGenerations[key] ?? []
        generations.append((base: base, snapshot: remapped,
                            actionCount: sessionActionCounts[key] ?? 0,
                            followsOwnAction: Self.currentCallID != 0
                                && lastActionCallIDs[key] == Self.currentCallID,
                            delivered: false))
        // 読み手へ返した世代は押し出さない(窓は最新 + 返した1本 + 古い順の残り)
        while generations.count > Self.maxRefGenerations,
              let evict = generations.firstIndex(where: { !$0.delivered }), evict < generations.count - 1 {
            generations.remove(at: evict)
        }
        refGenerations[key] = generations
        let maxNativeRef = native.elements.map(\.ref).max() ?? -1
        // **セッション共通の採番**(sessionKey ごとではない。宣言のコメント参照)
        nextRefBase = base + maxNativeRef + 1
        lastSnapshots[key] = remapped
        launchBaselineStale.remove(key)
        return remapped
    }

    /// ft_snapshot が読み手へ返した最新世代に印を付ける(前の印は外す。`refGenerations` の `delivered`)
    func markLastGenerationDelivered(args: [String: Any]) {
        let key = Self.sessionKey(args)
        guard var generations = refGenerations[key], !generations.isEmpty else { return }
        for index in generations.indices { generations[index].delivered = index == generations.count - 1 }
        refGenerations[key] = generations
    }

    /// セッション ref から要素を引く。世代を新しい順に探し、最初に見つかった世代の要素を返す。
    /// `isStale` = 最新世代以外で見つかった(= 撮り直した後にもっと新しい木が出ている)。
    ///
    /// **stale 判定はこの呼び出し時点の最新世代とだけ比べる**: 呼び手(verifiedRef 等)が
    /// この後で自分で撮り直して世代を進めても、それはエージェントが ref を送った**後**の話なので
    /// stale 扱いにしない。ここを先に評価してから撮り直すという順序を崩すと、時計のラベル変化
    /// だけで世代が進むたびに全タップへ偽の「older snapshot」警告が付く
    func resolveSessionRef(_ ref: Int, args: [String: Any])
        -> (element: ElementInfo, isStale: Bool)? {
        guard let generations = refGenerations[Self.sessionKey(args)] else { return nil }
        for (offset, generation) in generations.enumerated().reversed() {
            if let element = generation.snapshot.elements.first(where: { $0.ref == ref }) {
                return (element, offset != generations.count - 1)
            }
        }
        return nil
    }

    /// **ref を採った木と、今の木が同じアプリか**(「アプリ切替」の監査で実機再現)。
    ///
    /// ref の世代は sessionKey(= 機)ごとで、**アプリでは区切っていない**。同じ機で別アプリを
    /// 起動すると、前のアプリで採った ref が次のアプリの木に対して再照合され、
    /// **`#id` が同じなら黙って当たる**。E2E の 5 SUT は `#id`・ラベルが共通契約なので
    /// これは机上の話ではない —— 実測(iOS・同一機)で `com.ftester.e2e` の `#nav_selector`
    /// (ref 54)を採ってから `com.ftester.e2e.ios` を launch して撃つと `tap [54] done` で
    /// **別アプリの同名要素を叩き**、しかも注記は
    /// 「1px 動いた・周囲のレイアウトが変わった」と**自信を持って誤説明**した。
    /// `switchedAppNote` は「起動したアプリ = 前面」を見るので、明示 launch した後は発火しない
    /// —— 見ていないのは**ref の出自**のほうだった。
    ///
    /// **どちらかが不明なら何もしない**(旧ブリッジは sessionBundleID を返さない。
    /// 「分からない」を「変わった」と読むと毎回拒否になる)
    static func refFromAnotherAppMessage(ref: Int, takenFrom: SnapshotResponse?,
                                         fresh: SnapshotResponse) -> String? {
        guard let taken = takenFrom?.sessionBundleID, let now = fresh.sessionBundleID,
              taken != now else { return nil }
        return "[\(ref)] was taken from \(taken) but the app in front is now \(now)"
            + " — refusing, because refs are per-device and not per-app: sibling apps can expose"
            + " the same ids and labels, so this would silently hit a different app's element."
            + (now == SystemUITreeKind.systemUIPackage
                ? " The system UI (notification shade, quick settings or lock screen) is in front, so a fresh"
                    + " ft_snapshot would only show its tree: close it first (ft_navigate back), then take a fresh ft_snapshot."
                : " Take a fresh ft_snapshot and use the new refs.")
    }

    /// **ref を採ったときの木と、撃つ直前の木が違う**ことの警告(Simulator で再現)。
    ///
    /// なぜ要るか: 既存の警告はどれも**要素の見え方**を見ている(gone / ghost / moved /
    /// ラベル変化 / 遮蔽 / 別アプリ)ので、**同じ id・同じラベル・同じ frame の別インスタンス**を
    /// 掴んだときに1つも当たらない。実測 —— E2EAppCMP のセレクタ画面で `#btn_back`(ref 350)を
    /// 採り、**ツールの外から** `simctl openurl` でライフサイクル画面へ進めてから撃つと、
    /// `tap [350] done.` だけを返してライフサイクル画面の `#btn_back`(同じ frame・同じ「戻る」)を
    /// 叩く。`isStale` も当たらない —— 間に snapshot を挟んでいないので ref は最新世代のままだから。
    ///
    /// **しきい値を持たない**: 「木の類似度が閾値以下なら別画面」は固定コーパスで棄却済み
    /// (同じ画面の別状態 0.33 と別画面 0.30/0.35 が重なり、別画面で 0.92 のペアもある)。
    /// `adoptSnapshot` は同一性が変わらなければ世代を進めない = 同一性の一致がそのまま
    /// 「変わっていない」の表明なので、**厳密比較でよい**。
    ///
    /// **比較キーに ref と frame を入れない**: ref は世代でずれ、frame はスクロールで動くが、
    /// どちらも「画面が別物になった」ことを意味しない。
    ///
    /// **断定しない**: 木からは「別の画面か」を決められない(できないことは上の棄却が示している)。
    /// 事実(木が違う・このセッションが自分でそれをしたか)だけを述べて撮り直しを勧める。
    /// `isStale` のときは黙る —— あちらの注記が同じことを既に言っており、二重になる
    ///
    /// **`actedSinceTakenFrom`**: この ref を採った世代から、このセッションが
    /// この sessionKey へ何か(tap/type/swipe/…)を撃っていれば true。**「他プロセス/人が動かした」と
    /// 誤って名指ししない** —— 実測(5/5): 直前の自分の ft_tap で遷移した画面に対して
    /// このセッションの ref を撃つと、木が変わった原因を持たない外部要因のせいにしていた
    ///
    /// **`takenRightAfterOwnAction`**: その世代を、このセッションの操作と同じ呼び出しの中で操作の後に読んだなら true
    /// (snapshotAfter・waitFor)。操作の結果がまだ届き切っていない木(検索候補の読み込み中)から ref を採ると、
    /// 以後何もしていなくても木は変わる —— 実測(Apple マップ・Google マップ): ft_type の snapshotAfter の
    /// 候補を押すと「アプリ・他プロセス・人が動かした」と言っていた
    static func screenChangedUnderRefNote(ref: Int, takenFrom: SnapshotResponse?,
                                          fresh: SnapshotResponse, isStale: Bool,
                                          matched: ElementInfo, actedSinceTakenFrom: Bool,
                                          takenRightAfterOwnAction: Bool,
                                          loadingNoteShownBefore: Bool) -> String {
        // **畳まれる飾りの葉(地図の地点)は比べない**: 地図は利用者が何もしなくても地点を出し入れするので、
        // 含めると地図の画面では毎回「このセッションは何もしていないのに変わった」と言う(Apple マップの経路画面で
        // `#VKPointFeature` 133件の増減だけで発火)。**撃つ相手がその群の一員なら比べる**(地点そのものを撃つ形)
        let ignoresBulk = !SnapshotRenderer.foldedGroups(fresh, flagging: [:], collapsingBulk: true)
            .values.contains { $0.contains(matched.ref) }
        guard !isStale, let taken = takenFrom,
              Self.treeIdentity(taken, ignoringBulk: ignoresBulk)
                != Self.treeIdentity(fresh, ignoringBulk: ignoresBulk) else { return "" }
        // **操作の直後に読んだ木なら、読み込みの続きで変わっただけのことが多い**(実測: Apple マップの候補・経路で3回続けて
        // 正しい要素に当たっていた)。撃った先を名指しして事実だけ言い、撮り直しの命令は付けない(操作はもう済んでいる)
        // **1セッション1回**(`loadingNoteShownBefore`)。2回目以降も同じ事実で、撃った先は応答本文が名指しする
        if takenRightAfterOwnAction, !actedSinceTakenFrom {
            guard !loadingNoteShownBefore else { return "" }
            return " note: [\(ref)] was read while the screen was still updating after this session's own last"
                + " action (results loading, an animation); it was matched to \(RefGuard.describe(matched))"
                + " in the current tree. Said once per session — later refs read this way are matched silently."
        }
        let cause = actedSinceTakenFrom
            ? "this session's own actions since that snapshot are the likely cause"
            : "no action since that snapshot changed it — a list still coasting from an earlier swipe, the app"
                + " itself, another process or a person moved the screen on"
        return " note: [\(ref)] came from a snapshot whose tree no longer matches the current one,"
            + " and \(cause). It still matched \(RefGuard.describe(matched)), but that"
            + " can be the same-looking element of a different screen. Take a fresh ft_snapshot."
    }

    /// 木の同一性(型 + identifier + ラベルの集合)。`identity` と違い **ref を含めない** ——
    /// あちらは世代の据え置き判定用で、こちらは**別の木どうし**を比べる
    private static func treeIdentity(_ snapshot: SnapshotResponse, ignoringBulk: Bool) -> Set<String> {
        let bulk = ignoringBulk
            ? Set(SnapshotRenderer.foldedGroups(snapshot, flagging: [:], collapsingBulk: true)
                .values.joined())
            : []
        return Set(snapshot.elements.filter { !bulk.contains($0.ref) }.map {
            "\($0.type)\u{1}\($0.identifier ?? "")\u{1}\($0.label ?? "")"
        })
    }

    /// この ref を持っている**別の** sessionKey(= 別の宛先、または同じ機の別の指し方)。
    /// 拒否するときに出自を名指しするために使う —— 「不明な番号」とだけ言うと、
    /// 呼び手は撃ち間違いだと読んで同じ番号を別の宛先へ撃ち直す
    func otherKeyHolding(_ ref: Int, args: [String: Any]) -> String? {
        let current = Self.sessionKey(args)
        return refGenerations.first { key, generations in
            key != current
                && generations.contains { $0.snapshot.elements.contains { $0.ref == ref } }
        }?.key
    }

    /// 別の宛先(または別の指し方)で採った ref を撃たれたときの拒否文。sessionKey をそのまま出す。
    /// **`udid` を渡された呼び出しは sessionKey の port を呼び手が書いていない**(MCP が udid を
    /// その回のポートへ解決して載せる = injectingPort)ので、そう言い添える —— 言わないと、udid しか
    /// 渡していない呼び手に「このポートを指した」と読ませ、同じ端末のどこが変わったのか分からない
    static func refFromAnotherTargetMessage(ref: Int, takenUnder: String,
                                            firedAt: String, udid: String?) -> String {
        let resolvedNote = udid.map {
            " (this call gave udid \($0), which resolved to that port this time — one device can"
                + " answer on more than one bridge port: its in-app and xcuitest bridges, or a bridge"
                + " restarted on another port)"
        } ?? ""
        return "[\(ref)] was taken under a different target (\(takenUnder)), but this call addressed"
            + " \(firedAt)\(resolvedNote) — refusing, because ref numbers are scoped to the target they"
            + " were taken from. Forwarding it would let that bridge resolve the number in its own"
            + " numbering and silently operate a different element."
            + " Take a fresh ft_snapshot for this target and use the new refs."
    }

    /// `ref` を含む世代の snapshot 全体(movedTogether の兄弟比較に使う「同じ世代の他の要素」用。
    /// resolveSessionRef と同じ探索だが、要素1件ではなく世代の全体が要る)
    func generationSnapshot(containing ref: Int, args: [String: Any]) -> SnapshotResponse? {
        refGenerations[Self.sessionKey(args)]?.reversed()
            .first { $0.snapshot.elements.contains { $0.ref == ref } }?.snapshot
    }

    /// `generationSnapshot` と同じ世代の `actionCount`(この ref を採った時点で、このセッションが
    /// この sessionKey へ撃っていた操作の回数)。出自判定用 — 今の回数と比べて、
    /// 「このセッションがそれ以来何かを撃ったか」を言う
    func generationActionCount(containing ref: Int, args: [String: Any]) -> Int? {
        refGenerations[Self.sessionKey(args)]?.reversed()
            .first { $0.snapshot.elements.contains { $0.ref == ref } }?.actionCount
    }

    /// **直前の ft_type の後、キーボードが上がりきるのを待つ**(DSL の consumePendingTypeKeyboardCheck と同じ判定
    /// `KeyboardWait.shouldAwaitAppearance`)。type はキーボードの表示を待たずに返るので、待たずに撃つと、まだ画面の外にある
    /// キーボードが後から上がり、下端のボタンへのタップがキーボードに当たる(DSL で実測: E2EY-Flutter の反転チャット)。
    /// **読みを足さない**: 判定には verifiedRef がどうせ撮る木を使い、待つときだけ撮り直す。出なければそのまま返す
    func consumePendingTypeKeyboardCheck(_ fresh: SnapshotResponse, driver: AppDriver,
                                         args: [String: Any]) async throws -> SnapshotResponse {
        let key = Self.sessionKey(args)
        guard let pending = pendingTypeKeyboardChecks[key] else { return fresh }
        pendingTypeKeyboardChecks[key] = nil
        let knownAbsent = KeyboardWait.knownAbsent(
            current: sessions[key]?.keyboardKnownAbsent ?? false, before: pending.before?.keyboardFrame,
            after: fresh.keyboardFrame, screen: fresh.screen, waitExhausted: false)
        sessions[key, default: DeviceSession()].keyboardKnownAbsent = knownAbsent
        guard KeyboardWait.shouldAwaitAppearance(
            isAndroid: driver is AndroidDriver, before: pending.before?.keyboardFrame,
            after: fresh.keyboardFrame, screen: fresh.screen, typedNewline: pending.typedNewline,
            keyboardKnownAbsent: knownAbsent) else { return fresh }
        var read = fresh
        let deadline = ContinuousClock.now + .milliseconds(Int(KeyboardWait.appearSeconds * 1000))
        while ContinuousClock.now < deadline, !KeyboardWait.onScreen(read.keyboardFrame, screen: read.screen) {
            try await Task.sleep(for: .milliseconds(Int(KeyboardWait.pollSeconds * 1000)))
            read = try await freshSnapshot(driver, args: args)
        }
        sessions[key, default: DeviceSession()].keyboardKnownAbsent = KeyboardWait.knownAbsent(
            current: knownAbsent, before: pending.before?.keyboardFrame, after: read.keyboardFrame,
            screen: read.screen, waitExhausted: true)
        return read
    }

    /// この ref の世代が、このセッションの操作と同じ呼び出しの中で操作の後に読んだ木か(snapshotAfter・waitFor の読み)
    func generationFollowsOwnAction(containing ref: Int, args: [String: Any]) -> Bool {
        refGenerations[Self.sessionKey(args)]?.reversed()
            .first { $0.snapshot.elements.contains { $0.ref == ref } }?.followsOwnAction ?? false
    }

    /// セッション ref → native ref(ブリッジへ渡す番号)。**最新世代の base を引くことでしか
    /// 正しく戻せない** —— 渡してよいのは verifiedRef/verifiedElement が返した「撮り直した後の」
    /// ref だけという規約(古い世代の ref を渡すと、その世代の base を引いても、ブリッジは
    /// とうにその番号を再利用しているので無効)。世代が無ければ素通し
    func nativeRef(_ sessionRef: Int, args: [String: Any]) -> Int {
        guard let last = refGenerations[Self.sessionKey(args)]?.last else { return sessionRef }
        return sessionRef - last.base
    }

    /// スナップショット本文(注記一式 + 木)。ft_snapshot と `snapshotAfter` が共有する ——
    /// **2つ目の組み立てを作らない**(注記を1つ足したときに片方だけ出る事故を防ぐ)。
    /// `extraNote` は ft_snapshot の waitFor 用(すり替わりの直後・他の注記より前に置く)。
    /// `cache` は計測用の注入口(既定 nil = 呼ぶたびに新しく作る、production の全経路がこちら)。
    /// **snapshot を跨いで渡さない**——SnapshotAnnotationCache のコメント参照
    /// `foldsSelectorTables`: 曖昧ラベル・重複 id の表の明細(要素ごとの代替セレクタ)を畳むか。**ft_snapshot だけ
    /// false**(セレクタを書くために読む口)。操作の応答では畳む —— 計測4回続けて全エージェントが「毎回長い・読み飛ばす」と
    /// 指摘し、量は木の本体と同じくらいあった。事実(×N で一意に指せない)は残り、撃った要素のセレクタは ft_tap が出す。
    /// **既定値を置かない**(新しい呼び口に決めさせる)
    func snapshotBody(_ snapshot: SnapshotResponse, driver: AppDriver,
                              args: [String: Any], extraNote: String = "",
                              foldsSelectorTables: Bool,
                              cache: SnapshotAnnotationCache? = nil,
                              probesCovering: Bool = false) async -> String {
        let cache = cache ?? SnapshotAnnotationCache()
        // **背面のアプリのツリーを「今の画面」として返さない**: XCUITest の snapshot は
        // セッションのアプリに閉じているので、**別のアプリが前面に来ても同じ木を返し続ける**。
        // 実測(シミュレータで確定。症状の初出は iPhone 実機):
        // ステータスバーの「◀ 元のアプリへ」を踏んだタップで前面が別アプリに替わったのに、
        // snapshot は元アプリの画面を返し、エージェントからは「タップが効かない」に見えた
        var backgroundNote = await Self.backgroundedSessionNote(snapshot, driver: driver)
        // **照会が前面と答えても、こちらが送った事実は消えない**(実機で実際にそうなった。
        // `backgroundedByNavigate` の doc)。照会が既に言えているときは重ねない
        if backgroundNote.isEmpty, backgroundedByNavigate.contains(Self.sessionKey(args)) {
            let decision = Self.navigatedAwayNote(launched: launchedBundleIDs[Self.sessionKey(args)],
                                                  treeSession: snapshot.sessionBundleID,
                                                  switcherOpened: switcherOpenedByNavigate.contains(Self.sessionKey(args)),
                                                  isAndroid: driver is AndroidDriver)
            // iOS は記録を ft_launch でだけ消していたため、ツール外(simctl launch・手で開く)で戻っても偽の注記が出続けた。
            // 戻ったと言える証拠(/appstate が前面 + 覆い無し + 木の要素がライブのヒットテストで引き当てられる)が揃ったときだけ消す。
            // 実機 iPhone 13 のホーム画面は /appstate が前面と答えるが、アプリの要素は引き当てられない(unresolvable)ので消えない
            if !decision.appIsBack, !(driver is AndroidDriver),
               await iosAppIsBackOnScreen(snapshot, driver: driver, args: args) {
                backgroundedByNavigate.remove(Self.sessionKey(args))
                backgroundNote = ""
            } else {
                if decision.appIsBack { backgroundedByNavigate.remove(Self.sessionKey(args)) }
                backgroundNote = decision.note
            }
        }
        // 覆い(iOS のカバーシート・コントロールセンター等)は照会の費用があるので、呼び手が許したときだけ聞く(coveringNote の doc)。
        // SpringBoard のセッションは通知センター・スイッチャーそのものを木として読んでいる(正規の読み方)ので、「アプリの木で画面ではない」とは言わない
        if probesCovering, Self.shouldProbeCovering(sessionBundleID: snapshot.sessionBundleID) {
            backgroundNote = await Self.coveringNote(driver: driver) + backgroundNote
        }
        // **すり替わりを先頭に置く**: これが起きているとき、以下の一覧は丸ごと別アプリのもので、
        // ghost 注記も scrollFrame 候補も読む意味が無い
        let switchedLaunched = launchedBundleIDs[Self.sessionKey(args)]
        let switchedNote = Self.switchedAppNote(
            launched: switchedLaunched, snapshot: snapshot,
            processEvidence: androidProcessEvidenceForSwitch(
                launched: switchedLaunched, snapshot: snapshot, driver: driver, args: args),
            stoppedByTool: toolStoppedBundleIDs[Self.sessionKey(args)],
            keyguardShowing: await Self.keyguardFact(for: snapshot, driver: driver))
            // セッションが SpringBoard のまま、木がほぼ空(ステータスバーだけ)= ホーム画面から開いたアプリを見ていない
            + (snapshot.sessionBundleID == Self.springboardBundleID
                && Self.unrepresentedScreenFraction(snapshot) >= Self.unrepresentedScreenCaveatThreshold
                ? "note: this session is attached to SpringBoard and its tree is nearly empty — an app opened from the"
                    + " home screen is not the session's app. Point the session at it with ft_launch <bundleId> resume: true.\n"
                : "")
        // **launch 系ツールの直後だけ・一度だけ** system alert を確かめる
        // (systemAlertProbePending 参照。DSL の noteAppLaunched と同じ設計)。
        // **先に鍵を消してから probe する** —— この呼び出し自体が非同期で待つため、
        // 消し忘れると再入(snapshotAfter 経由の二重呼び出し等)で二重に払う
        var alertNote = ""
        let alertKey = Self.sessionKey(args)
        // **操作の後なのに木が前と同じ**(adoptSnapshot が世代を使い回した)ときも1回だけ聞く。アプリ自身のタップで出た権限アラートは
        // 前面でも木はアプリの背面の木のまま変わらない。毎手の往復(約 0.6 秒)は払わず、変化が無かった手の後だけ・同じ操作の後は1回だけ
        let probesAfterUnchangedTree = Self.shouldProbeAfterUnchangedTree(
            isAndroid: driver is AndroidDriver,
            lastGenerationActionCount: refGenerations[alertKey]?.last?.actionCount,
            sessionActionCount: sessionActionCounts[alertKey] ?? 0,
            probedAtActionCount: alertProbedAtActionCounts[alertKey])
        if probesAfterUnchangedTree { alertProbedAtActionCounts[alertKey] = sessionActionCounts[alertKey] ?? 0 }
        if systemAlertProbePending.contains(alertKey) || probesAfterUnchangedTree {
            systemAlertProbePending.remove(alertKey)
            let alert = await Self.systemAlertNote(driver: driver)
            if !alert.isEmpty {
                alertNote = alert + "\n"
                // **出ている間は次の応答でも確かめる**(閉じるまで木を伏せ続ける)。閉じたら照会も止む
                systemAlertProbePending.insert(alertKey)
            }
        }
        // **アラートが前面にある間はアプリの木を出さない**(ユーザー決定): 背面の木は押せない要素の一覧で、
        // 読み手はそこから次の手を探してしまう。注記(木から決まるもの)も背面の木の話なので出さない
        if !alertNote.isEmpty {
            return switchedNote + alertNote + extraNote + backgroundNote
        }
        // **ghostNote と render で畳みの有無を揃える**: 片方だけ expandBulk を無視すると、
        // 注記は「畳んだ」と言うのに木は個別列挙、という食い違いになる
        let collapsingBulk = args["expandBulk"] as? Bool != true
        // **木だけから決まる注記は NoteCatalog が唯一の定義元**(並び順・短縮・A/B の黙らせも
        // あちら)。ここへ直に `Self.xxxNote(...)` を足さないこと —— 足すと発火が測れなくなり、
        // NoteCoverageTests のソース走査が落ちる
        // **勝手に上限を上げたことは名乗る**(黙って出力量が3倍になると、読み手は
        // 自分の指定が効いていないと読む)。初回だけ満額 —— 以後は同じ device で常時なので
        let ceilingNote = webPageCeilingLatched.contains(Self.sessionKey(args))
            ? once("webPageCeilingRetake",
                   full: "note: this device showed a truncated web page, so snapshots for it are"
                       + " now taken at the \(BridgeAPI.maxSnapshotElementsCeiling)-element ceiling"
                       + " instead of the \(BridgeAPI.maxSnapshotElements) default — on a web page"
                       + " the dropped elements are the labelled body text, and they are gone from"
                       + " the tree rather than off screen (scrolling never brings them back)."
                       + Self.shorteningAdvice(snapshot, cache: cache) + "\n",
                   short: "")
            : ""
        // 木を読み手へ返す口はここ1箇所(ft_snapshot / snapshotAfter / ft_batch の末尾 / ft_rotate / ft_fold)。返した世代は窓から押し出さない
        markLastGenerationDelivered(args: args)
        if let inAppAlert = AlertTreeScope.frontInAppAlert(in: snapshot) {
            return switchedNote + ceilingNote + extraNote + backgroundNote
                + Self.inAppAlertNote(inAppAlert, in: snapshot)
                + SnapshotRenderer.render(AlertTreeScope.alertOnly(inAppAlert, in: snapshot), flagging: [:],
                                          collapsingBulk: collapsingBulk, interactiveOnly: false,
                                          unit: Self.coordinateUnit(driver))
        }
        return switchedNote + alertNote + ceilingNote + extraNote + backgroundNote
            + catalogNotes(NoteCatalog.Input(snapshot: snapshot, collapsingBulk: collapsingBulk,
                                             cache: cache,
                                             brief: Self.briefKeys(foldsSelectorTables: foldsSelectorTables),
                                             actionResponse: foldsSelectorTables),
                           context: .snapshot)
            + SnapshotRenderer.render(snapshot, flagging: cache.ghostFlags(snapshot),
                                      collapsingBulk: collapsingBulk,
                                      interactiveOnly: args["interactiveOnly"] as? Bool == true,
                                      unit: Self.coordinateUnit(driver))
    }

    /// 木に添える座標の単位。**ドライバの実体で決める**(args の platform は省略されうる)。
    /// 判定は純粋関数に分けてある —— `AndroidDriver` の生成には adb の実在が要るので、
    /// これを分けないと単位の規則をテストするだけでホストの都合に縛られる
    static func coordinateUnit(_ driver: AppDriver) -> String {
        coordinateUnit(isAndroid: driver is AndroidDriver)
    }

    static func coordinateUnit(isAndroid: Bool) -> String { isAndroid ? "px" : "pt" }

    /// `snapshotAfter` が読む木は基本的に整定を待たないという注意を初回だけ満額で出す
    /// (settle-lite 追加後も「基本的に」待たない: 直後の木が操作前と見分けが
    /// 付かないときだけ、snapshotAfterBody が1回だけ短い待ちを挟んで撮り直す)。
    /// 実測: ft_type の直後は候補リストがまだネットワーク待ちで、waitFor 付きの ft_snapshot なら
    /// 出るものが「候補なし」に見えた
    /// **満額を短くした**。実運用の記録で**最もバイトを食っている注記**だった
    /// (20 run で 7,180 B = 359 B を毎 run 満額で。Bench/measurements.md)。
    /// 落としたのは「不変に見えたら1回だけ待って撮り直した(上の注記を見よ)」の説明 ——
    /// **それが実際に起きた回には settle-lite の注記そのものが出る**ので二重だった。
    /// 残したのは行動に要る2つ:「操作直後の木である」と「waitFor で確かめてから無いと言え」
    private func immediateReadNote() -> String {
        once("snapshotAfterImmediateNote",
            full: "note: this tree was read immediately after the action — a dynamic list (search suggestions, network"
                + " results) or a sheet or window still animating in may not be in it yet. If something you expect is"
                + " missing, confirm with ft_snapshot waitFor before concluding it is absent.\n",
            short: "(immediate read — see the first snapshotAfter note)\n")
    }

    /// 直後の木が操作前と区別できないときだけ挟む、1回きりの短い再読(settle-lite)。
    /// **value と frame を比較に含めるのが要点**: ft_type 直後は value が変わるので「変化あり」に
    /// なり無駄な待ちが入らない/ スクロールを伴うタップは frame が動くので同じ理由で入らない。
    /// **push 遷移が主目的**: 操作直後の木が古いまま返り、snapshotAfter が空振りして
    /// 別途 ft_snapshot を要求される実測から。
    /// **FTCore.StaleFrameDetector へ寄せない**: あちらの指紋は ref/type/identifier/
    /// label/frame までで、value/checked の変化には反応しない(あちらはスクリーンショットの
    /// 鮮度判定用で、ここが要る「入力しただけの変化」を感知できない)
    /// **同一性判定はこの1本だけ**(ft_batch も跨いで呼ぶ。2つ目を書かない)
    /// **truncatedCount も見る**(監査): `elements` はブリッジ側で既に
    /// maxSnapshotElements(既定120)へ切り詰め済みなので、変化が切り詰められた側だけに
    /// 起きると `elements` は同一のまま検知できない(実測: iOS Safari の横スクロール表で
    /// タップ後に +113 件がすべて cutoff の下に並び、生存 120 行はバイト同一だった)。
    /// **bulkExemptCount は見ない**: bulk 群(BridgeSnapshotThinning)は cap の外でも常に
    /// `elements` へ送られる(捨てられない)ので、その増減は既に `elements` の差分に現れており、
    /// 二重に見る意味が無い
    /// **キーボードの出入りも変化に数える**(`KeyboardWait.isShown`。キーボードはアプリの木の外で、窓が縮まない画面では
    /// ft_hide_keyboard・改行だけの ft_type の後も木は同一 = 閉じたのに「効かなかったかも」と言っていた)
    static func looksUnchanged(_ before: SnapshotResponse, _ after: SnapshotResponse) -> Bool {
        guard KeyboardWait.isShown(before) == KeyboardWait.isShown(after),
              before.elements.count == after.elements.count,
              before.truncatedCount == after.truncatedCount else { return false }
        return zip(before.elements, after.elements).allSatisfy { a, b in
            a.ref == b.ref && a.type == b.type && a.identifier == b.identifier
                && a.label == b.label && a.value == b.value && a.checked == b.checked
                && a.frame == b.frame
        }
    }

    /// **画面のどれだけが木に一つも表れていないか**(0〜1、画面高比)。空/ほぼ空の木は
    /// 「空 == 空」で必ず `looksUnchanged` に一致するため、この比率が高いときは
    /// 「unchanged」系の注記に「そもそも公開されていないだけかもしれない」ことを言い添える
    /// (unrepresentedScreenCaveat 参照)。**算出は `unrepresentedScreenFraction`
    /// (MCPServer+Hints.swift)に委ねる**(2つ目の計算を作らない)
    static let unrepresentedScreenCaveatThreshold = 0.5

    /// `looksUnchanged` 系の verdict(waitForChange タイムアウト・settle-lite・waitFor の
    /// 「action itself may not have taken effect」・ft_batch の「still identical」)へ共通で足す
    /// 注意書き。実測(Android Chrome): 木がブラウザ chrome の19要素(後に1要素)だけのまま、
    /// ft_batch の scrollDown ×4 が画面を実際に数スクロール分動かしたのに「変化なし」と返った ——
    /// ページの中身がそもそも a11y tree に載っていなかった。
    /// **失敗にはしない**(既存の note を補足するだけ)。返り値は先頭にスペース1つを含む断片
    /// (呼び手の文へそのまま連結する。独立行にするときは呼び手側で `\n` を足す)
    static func unrepresentedScreenCaveat(_ snapshot: SnapshotResponse) -> String {
        let fraction = unrepresentedScreenFraction(snapshot)
        guard fraction >= unrepresentedScreenCaveatThreshold else { return "" }
        return " (note: \(Int((fraction * 100).rounded()))% of the screen has no element in the"
            + " tree at all, so \"unchanged\" cannot tell \"nothing moved\" from \"nothing was"
            + " published\" — use ft_screenshot to see what is actually on screen.)"
    }

    /// **中身が1つも入っていない大きなスクロール容器**の名前(無ければ nil)。
    ///

    /// waitFor は snapshotAfter の待ち方の指定であって独立の引数ではない。
    /// snapshotAfter なしで渡されたら黙って無視せず気付かせる —— **throw はしない**
    /// (操作そのものは既に実行済みなので、ここで落とすと二重操作を誘う)
    func waitForWithoutSnapshotAfterNote(_ args: [String: Any]) -> String {
        guard args["snapshotAfter"] as? Bool != true else {
            // **併用は黙って waitFor が勝つ形にしない**: 待つ理由が違う(選択子の出現 対
            // 木の変化)ので、片方が無視されたことは言う
            guard args["waitFor"] != nil, args["waitForChange"] as? Bool == true else { return "" }
            return " (note: waitForChange was ignored — waitFor was given and takes precedence)"
        }
        let given = [args["waitFor"] != nil ? "waitFor" : nil,
                     args["waitForChange"] as? Bool == true ? "waitForChange" : nil].compactMap { $0 }
        guard !given.isEmpty else { return "" }
        return " (note: \(given.joined(separator: "/")) requires snapshotAfter: true —"
            + " it was ignored)"
    }

    /// ft_scroll_to の失敗文の本体。**シート展開の救済を撃った回は総称の「シートを広げて再試行」を外す**
    /// (救済が同じことを試し、その結果を sheetNote が言っている。残すと「3回目もうまくいかない」の直後に
    /// 「広げて再試行」と言う矛盾になる = 計測で指摘)
    static func scrollFailureReason(_ message: String, sheetRescued: Bool) -> String {
        sheetRescued ? message.replacingOccurrences(of: StepExecutor.halfOpenSheetHint, with: "") : message
    }

    /// 直近に明示された指定(`rememberedSnapshotFilters`)を、木を返す応答へ引き継ぐ。
    ///
    /// **木を返す口はすべてここを通す**(`ft_snapshot`・`snapshotAfter`・`ft_scroll_to`)。片方だけ継承すると
    /// 「interactiveOnly を渡した後、どのツールで読むかで出力量が変わる」になり、読み手は
    /// 自分の指定が効いていないと読む —— 実際に `ft_scroll_to` だけが継承せず、
    /// 継承しなかったことも言っていない形になっていた。
    /// **明示された値が常に優先**: args に無いキーだけ記憶で補う。補った値が true の
    /// ときだけ宣言する(false を補っても render の既定と同じなので出力は変わらない)
    /// **木を返すツールに明示した指定も覚える**(キーごとに上書き)。ft_snapshot の指定しか覚えていなかったので、
    /// `ft_launch interactiveOnly: true snapshotAfter: true` の次の ft_tap が全行の木を返していた(実測: 計測の
    /// エージェント3人が同じ指摘)
    func inheritingSnapshotFilters(_ args: [String: Any]) -> (args: [String: Any], note: String) {
        let key = Self.sessionKey(args)
        var effective = args
        var note = ""
        for filterKey in ["interactiveOnly", "expandBulk"] {
            if let explicit = args[filterKey] as? Bool {
                // 宣言し直すのは**値が変わったときだけ**(同じ値を明示し直すたびに宣言すると、毎回明示する読み手には
                // 毎回出る = 計測で4回出た)
                if rememberedSnapshotFilters[key]?[filterKey] != explicit {
                    announcedInheritedFilters[key]?.remove(filterKey)
                }
                rememberedSnapshotFilters[key, default: [:]][filterKey] = explicit
                continue
            }
            guard let remembered = rememberedSnapshotFilters[key]?[filterKey] else { continue }
            effective[filterKey] = remembered
            if remembered, announcedInheritedFilters[key, default: []].insert(filterKey).inserted {
                note += "(\(filterKey): true inherited from an earlier call —"
                    + " pass \(filterKey): false to override; it is inherited silently until you pass a different value)\n"
            }
        }
        return (effective, note)
    }

    /// 操作系ツールが `snapshotAfter: true` で返す「操作の直後の画面」。
    ///
    /// **往復を半分にするためにある**: tap/type/drag は「変わったかもしれない」で終わるので、
    /// 読み手はほぼ必ず ft_snapshot を続けて撃つ。実測(マップ探索1セッション)では
    /// 46 回の呼び出しのうち 21 回が**この確認だけの snapshot** だった。
    ///
    /// **撮るのは操作の直後**。木が操作前(`lastSnapshots`)と見分けが付かないときだけ、
    /// `settleWaitSeconds` だけ待って1回だけ撮り直す(settle-lite。looksUnchanged 参照) ——
    /// 撮り直しても同一なら「変わっていないかもしれない」と言うだけで、それ以上は待たない。
    /// 操作前の木を知らない(`lastSnapshots` が無い)ときは何もしない。
    /// **失敗しても throw しない**: 操作自体は成功しているので、ここで throw すると
    /// 「タップは効いたのにエラーが返る」になり、読み手が操作を撃ち直して二重操作になる。
    /// **waitFor があれば settle-lite の代わりにそちらを使う**(両方は走らせない)
    /// `outsideTheAppTree`: 操作の相手がアプリの木に出ない(SpringBoard のアラート・ホーム画面・別のアプリ)。閉じても
    /// アプリの木は変わらないのが正常なので、操作前の木との比較(「効かなかったかも」)をしない。
    /// **既定値を置かない** —— 新しい呼び手に「相手はアプリの木の中か」を決めさせる(書き忘れをコンパイルで止める)
    /// `unchangedIsExpected`: 操作が画面を変えないと撃つ前に分かっている(スライダーが既に目標の値)。木が変わらないのは正しいので
    /// 撮り直しも「効かなかったかも」の注記も出さない(実測: 同じ値を2回入れると「read the screen again before repeating」と誤誘導した)。
    /// `baseline`: 操作の前の木。**操作と snapshotAfter の間に `freshSnapshot` で読む呼び手は渡す** —— `adoptSnapshot` が
    /// `lastSnapshots` を後の木で上書きし、後の木どうしを比べて「unchanged」と言う(実測: CMP iOS の帯のタップの経路で 25→50 に動いたのに出た)
    func snapshotAfterBody(_ args: [String: Any], outsideTheAppTree: Bool, unchangedIsExpected: Bool = false,
                           baseline: SnapshotResponse? = nil) async -> String {
        await snapshotAfterBodyWithStatus(args, outsideTheAppTree: outsideTheAppTree, unchangedIsExpected: unchangedIsExpected,
                                          baseline: baseline).text
    }

    /// `snapshotAfterBody` 本体。**back の無効判定(ft_navigate)が succeeded を見る**
    ///: catch した回(読みに失敗した回)は `lastSnapshots` が back 前の木のまま
    /// 残るため、`succeeded` を返さずに「今の lastSnapshots」だけを見ると back 前の木と
    /// 指紋が自明に一致し、謝罪文の横に「back は効かなかった」という偽の注記が並ぶ
    /// (実測)。他の呼び出し口は text だけを使い、この差は見ない
    func snapshotAfterBodyWithStatus(_ args: [String: Any], outsideTheAppTree: Bool,
                                     unchangedIsExpected: Bool = false,
                                     baseline: SnapshotResponse? = nil) async -> (text: String, succeeded: Bool) {
        guard args["snapshotAfter"] as? Bool == true else { return ("", false) }
        SlowCallWatchdog.mark("reading the screen after the action")
        do {
            let snapshotDriver = try await driver(args)
            let key = Self.sessionKey(args)
            let beforeAction = outsideTheAppTree ? nil : baseline ?? lastSnapshots[key]

            let (effectiveArgs, inheritedNote) = inheritingSnapshotFilters(args)

            var snapshot = try await freshSnapshot(snapshotDriver, args: args)
            // 直前の type のキーボードが上がりきる前の木を操作後の木として返さない(印が無ければ何も読まない)
            snapshot = try await consumePendingTypeKeyboardCheck(snapshot, driver: snapshotDriver, args: args)
            var settleNote = ""
            var waitNote = ""
            // 撮り直しても操作の前と変わらなかった = 覆いの下の形(coveringNote の doc)。このときだけ覆いを聞く
            var stillUnchanged = false
            // **waitFor は settle-lite の代わり**(併用しない): 待つ理由が同じ(木がまだ
            // 追いついていない)なので、両方は二重に待つだけ。パターンは ft_snapshot の
            // waitFor 分岐と同じ(refetched の扱いも含め)
            if let waitFor = args["waitFor"] as? String {
                let seconds = try Self.doubleArgument(args, "waitSeconds") ?? Self.defaultWaitSeconds
                let waited = try await Self.waitFor(waitFor, driver: snapshotDriver,
                                                    first: snapshot, seconds: seconds,
                                                    elementLimit: try pollElementLimit(args))
                snapshot = waited.refetched ? adoptSnapshot(waited.snapshot, args: args) : waited.snapshot
                let unchangedSinceAction = !waited.found
                    && beforeAction.map { Self.looksUnchanged($0, snapshot) } == true
                let dialogHint = unchangedSinceAction
                    ? await Self.systemDialogHint(bridge: bridges[Self.sessionKey(args)], driver: snapshotDriver) : ""
                let explainMiss = waited.found ? false : firstTime("waitMissExplained")
                waitNote = waited.found
                    ? Self.waitForAppearedNote(waitFor, in: snapshot,
                                               collapsingBulk: effectiveArgs["expandBulk"] as? Bool != true) + Self.waitMatchedBeforeNote(waitFor, before: beforeAction, now: snapshot, canWaitForChange: Self.toolDeclares("waitForChange", tool: Self.currentTool))
                    : Self.waitMissHeadline(waitFor, seconds: seconds, quietStopAfter: waited.quietStopAfter,
                                            explain: explainMiss,
                                            // ft_launch は waitForChange を持たない = 持つツールでだけ案内する
                                            canWaitForChange: Self.toolDeclares("waitForChange", tool: Self.currentTool))
                        + Self.appearedPromptNote(before: beforeAction, now: snapshot)
                        + " — this is the screen as it is now\(Self.truncationHint(snapshot))"
                        + (waited.partialSeenAfter.map { seenAfter in
                            " — a partial match was already on screen \(Int(seenAfter.rounded()))s"
                                + " into the wait:\(waited.partialHint) The exact form never"
                                + " appeared, so the wait ran to the deadline"
                        } ?? (Self.notationHint(waitFor, in: snapshot)
                              + Self.similarLabelsHint(waitFor, in: snapshot)))
                        + Self.waitForScrollHint(in: snapshot, explain: explainMiss)
                        // **操作の効果も疑う**(監査): waitFor はここでしか「操作前の木」
                        // を持たない(ft_snapshot 単独には操作前が無い)。判定は settle-lite/
                        // waitForChange と同じ looksUnchanged を再利用する(2つ目の同一性判定を書かない)
                        + (unchangedSinceAction
                           ? " the tree is also identical to the one before the action, so the"
                             + " action itself may not have taken effect."
                             + Self.unrepresentedScreenCaveat(snapshot)
                             + dialogHint
                           : "") + "\n"
            } else if args["waitForChange"] as? Bool == true {
                SlowCallWatchdog.mark("waiting for the screen to change")
                let result = try await waitForChangeBody(beforeAction: beforeAction,
                                                         snapshot: snapshot,
                                                         driver: snapshotDriver, args: args)
                snapshot = result.snapshot
                settleNote = result.note
            } else if !unchangedIsExpected, let beforeAction, Self.looksUnchanged(beforeAction, snapshot) {
                // 撮り直しの段は分ける(「操作の後の読み」が平均 0.94s で、待ちと読みのどちらか分からなかった = 計測)
                SlowCallWatchdog.mark("re-reading: the tree looked unchanged")
                let reread = try await rereadAfterGrace(snapshotDriver, args: args)
                if Self.looksUnchanged(snapshot, reread) {
                    stillUnchanged = true
                    settleNote = "note: the tree still looked unchanged after a short re-read"
                        + " wait — the action may not have changed the screen, or a window it opened"
                        + " has not reached the tree yet (an overlay window took about a second): read the"
                        + " screen again before repeating the action."
                        + Self.unrepresentedScreenCaveat(reread)
                        + (await Self.systemDialogHint(bridge: bridges[Self.sessionKey(args)],
                                                       driver: snapshotDriver)) + "\n"
                } else {
                    settleNote = "note: the tree looked unchanged right after the action, so it"
                        + " was re-read once after a short wait — the tree below is the re-read.\n"
                }
                snapshot = reread
            } else if let settled = try await Self.rereadIfEmptyOrBlank(snapshot, reread: {
                try await self.rereadAfterGrace(snapshotDriver, args: args)
            }) {
                settleNote = settled.note
                snapshot = settled.snapshot
            }
            recordSnapshot(snapshot, snapshotDriver is AndroidDriver ? "android" : "ios", args)
            // waitFor / waitForChange / 撮り直し(settleNote)の後の木は「待たずに読んだ」のではないので immediateReadNote を
            // 出さない(計測で指摘: waitForChange が成立した応答に「操作の直後に読んだ」と付いていた)
            let readNote = waitNote.isEmpty && settleNote.isEmpty ? immediateReadNote() : ""
            SlowCallWatchdog.mark("composing the tree and notes")
            let body = "\n\n" + inheritedNote + waitNote + settleNote + readNote
                + (await snapshotBody(snapshot, driver: snapshotDriver, args: effectiveArgs,
                                      foldsSelectorTables: true, probesCovering: stillUnchanged))
            return (body, true)
        } catch {
            let body = "\n\n(snapshotAfter could not read the screen:"
                + " \(error.localizedDescription) — the action above still went through;"
                + " take an ft_snapshot yourself)"
            return (body, false)
        }
    }

    /// scrollFrame の注記を計算する木。**探索の後の木にその容器があるなら後の木**、無ければ探索前の木
    /// (探索がシートを畳んで容器が消えた形では、前の木のほうが正しい)。前の木はセッションが最後に覚えた木で、
    /// `snapshotAfter: false` の操作の後は**古い画面のまま**のことがある(実測: 閉じた詳細画面の木で「今の画面にある
    /// 容器が無い」と言い、閉じた画面の容器を候補に挙げた)
    static func scrollFrameHintTree(_ args: [String: Any], before: SnapshotResponse?,
                                    after: SnapshotResponse) -> SnapshotResponse {
        guard let before else { return after }
        // scrollFrame を渡さない呼び出しは探索後の木(前の木は別のツールの呼び出しの木のことがある)
        guard let frame = args["scrollFrame"] as? String else { return after }
        // 構文が誤りなら前の木(探索は門 validateScrollFrameArg で既に断っている)
        guard let locator = (try? Self.parseSelectorArgument(frame, argument: "scrollFrame"))?.primary else { return before }
        let inAfter = !(LocatorResolver.candidates(locator, elements: after.elements) ?? []).isEmpty
        return inAfter ? after : before
    }

    /// アプリ内のアラートの注記(木はアラートの部分木だけ = `AlertTreeScope`)
    static func inAppAlertNote(_ alert: ElementInfo, in snapshot: SnapshotResponse) -> String {
        let buttons = AlertTreeScope.buttonLabels(of: alert, in: snapshot)
        return "note: \(RefGuard.describe(alert)) is in front of the app"
            + (buttons.isEmpty ? "" : " (buttons: " + buttons.map { "\"\($0)\"" }.joined(separator: " / ") + ")")
            + ". The screen behind it is left out of the list below — nothing there can be reached until the"
            + " alert is closed. It is part of the app's tree, so press its button with ft_tap selector: \"<button>\" (or its ref).\n"
    }

    /// 明細を畳む注記の鍵(`FT_MCP_NOTES_BRIEF` の指定に足す)
    static func briefKeys(foldsSelectorTables: Bool) -> Set<String> {
        foldsSelectorTables ? NoteCatalog.brief.union(["ambiguousLabelsNote", "duplicateIDsNote"]) : NoteCatalog.brief
    }

    /// 操作の後の木が「空の一覧」または「何も読めない」ときだけ1回撮り直す(snapshotAfter と ft_batch の最終読みが共有。
    /// 「空」「何も読めない」の定義を2つ持たない)。どちらでもなければ nil。猶予は settle-lite と同じ1回きり
    static func rereadIfEmptyOrBlank(_ snapshot: SnapshotResponse,
                                     reread: () async throws -> SnapshotResponse) async rethrows
        -> (note: String, snapshot: SnapshotResponse)? {
        if let empty = emptyLoadingScroller(in: snapshot) {
            SlowCallWatchdog.mark("re-reading: a list was still empty")
            // **木は変わったのに中身がまだ来ていない**形(emptyLoadingScroller 参照)
            let again = try await reread()
            let name = RefGuard.describe(empty)
            if emptyLoadingScroller(in: again) == nil {
                return ("note: \(name) was still empty right after the action, so the tree"
                    + " was re-read once after a short wait — the tree below is the re-read.\n", again)
            }
            // **埋まらなかったら黙らない**: 正当に空(検索結果0件)のこともあるので断定せず「空のまま」とだけ言う
            return ("note: \(name) is still empty after a short re-read wait — it may"
                + " be genuinely empty, or still loading; use ft_snapshot waitFor if you"
                + " expect content in it.\n", again)
        }
        if looksBlank(snapshot) {
            SlowCallWatchdog.mark("re-reading: nothing readable yet")
            // **何も読めない木**(全要素がレイアウト専用 = 遷移の途中)。黙って返すと読み手は空の木から次の一手を探す
            // (実測: Apple マップで全画面シートを閉じた直後の木が layout-only の1行だけ)
            let again = try await reread()
            return (looksBlank(again)
                ? "note: the screen still had nothing readable after a short re-read wait — a transition may"
                    + " still be running; use ft_snapshot waitFor: <something you expect on the next screen>.\n"
                : "note: the tree right after the action had nothing readable on it (a transition in"
                    + " progress), so it was re-read once after a short wait — the tree below is the re-read.\n", again)
        }
        return nil
    }

    /// 何も読めない木か(要素が無い、または全要素が interactiveOnly で隠れるレイアウト専用)。判定は描画側の
    /// `isHiddenByInteractiveOnly` を共有する(2つ目の「中身があるか」を書かない)
    static func looksBlank(_ snapshot: SnapshotResponse) -> Bool {
        SnapshotRenderer.hiddenByInteractiveOnlyCount(snapshot) == snapshot.elements.count
    }

    /// `snapshotAfterBodyWithStatus` の waitForChange 分岐(waitFor の隣の抽出)。
    /// **beforeAction が無ければ待たない**(比較対象が無いので「変わった」と言う材料が無い)。
    /// 戻り値の snapshot は撮り直した最新の木(呼び手はこれで自分の `snapshot` を置き換える)
    func waitForChangeBody(beforeAction: SnapshotResponse?, snapshot initial: SnapshotResponse,
                           driver: AppDriver, args: [String: Any]) async throws
        -> (snapshot: SnapshotResponse, note: String) {
        guard let beforeAction else {
            return (initial, "note: waitForChange had no earlier tree to compare with"
                + " (nothing was read on this device yet), so it did not wait.\n")
        }
        var snapshot = initial
        let seconds = try Self.doubleArgument(args, "waitSeconds") ?? Self.defaultWaitSeconds
        let deadline = Date().addingTimeInterval(max(0, seconds))
        var changed = !Self.looksUnchanged(beforeAction, snapshot)
        let changedOnFirstRead = changed
        while !changed, Date() < deadline {
            try await Task.sleep(for: .seconds(Self.waitPollSeconds))
            snapshot = try await freshSnapshot(driver, args: args)
            changed = !Self.looksUnchanged(beforeAction, snapshot)
        }
        guard changed else {
            return (snapshot, "note: waitForChange timed out after \(Self.secondsText(seconds))"
                + Self.waitTimeoutRemedy + " — the tree"
                + " still matches the one before the action, so the action may not"
                + " have changed the screen."
                + Self.unrepresentedScreenCaveat(snapshot) + "\n")
        }
        // **「変わった」は「終わった」ではない**: 最初に差が出た木が遷移途中のこともある
        // (実測: 検索結果がまだネットワーク待ちの「候補なし」中間状態で確定を
        // 返した)。直前の読みと一致するまで少数回だけ読み直して採り直す。waitSeconds には縛らない
        // (settle-lite と同じく操作後の固定小コストであって、待ち時間の指定ではない)
        var churn = 0
        var stable = false
        // 変化を待った時間と、変わった後の安定確認の時間を分ける(waitForChange が平均約 1s で、どちらが主か分からなかった)
        SlowCallWatchdog.mark("confirming the change has settled")
        for _ in 0..<Self.changeSettleRereads {
            let reread = try await rereadAfterGrace(driver, args: args)
            if Self.looksUnchanged(snapshot, reread) { stable = true; break }
            snapshot = reread
            churn += 1
        }
        var note = "waitForChange: the tree differs from the one before the action.\n"
        if !stable {
            note += "note: the tree was still changing between re-reads —"
                + " it may not have settled; re-check (ft_snapshot, optionally"
                + " waitFor) before relying on it.\n"
        } else if churn > 0 {
            note += "note: it kept changing after the first difference —"
                + " the tree below is the latest read.\n"
        } else if changedOnFirstRead {
            // 安定確認は「中間状態がそれ自体しばらく静止している」場合を
            // 見抜けない —— 遷移を1度も観測していないことだけは言える
            // **「確かめろ」で終えない**: 旧文はここまで来た木が
            // 何を通っているかを言わずに確認だけ促しており、読み手は素の ft_snapshot を
            // もう1回撃っていた —— この分岐は `stable && churn == 0`、つまり
            // **撮り直して同一だった**ときにしか来ないので、同じ木がもう1枚返るだけの丸損。
            // 済んでいることを先に言い、残る唯一の疑い(静止した読み込み中)と、
            // それに効く**別の**手(waitFor)を名指しする
            note += once("waitForChangeFirstReadNote",
                // 「遷移は観測されなかった」と書くと、遷移が確かに起きた場面で誤読される(計測で指摘)。
                // 言いたいのは「読む前に終わっていた」
                // 4文あり長いと計測で繰り返し指摘された。残すのは「済んでいる・撮り直しても同じ」と、唯一の疑い(静止した読み込み中)に効く手
                full: "note: the change had already completed by the first read and the tree has stopped changing —"
                    + " another ft_snapshot returns the same tree. A loading or empty state can be stable too, so if you"
                    + " expect specific content, wait for it with ft_snapshot waitFor: <selector>.\n",
                // 短縮形も出さない: 画面遷移のタップでは「初回で差があった」のが当然で、7回の tap 全部に付いていた(計測で指摘)
                short: "")
        }
        return (snapshot, note)
    }

    /// 「木が画面を代表していない」の申告由来の警告。**覆いを先に聞く**(実機で実測):
    /// 通知センターが出ているときは覆いの検知と `hitTest` の**両方**が発火し、後者は
    /// 「アプリスイッチャーが開いている」という**誤った説明**を並べてしまう。
    /// 面が分かっているならそちらが正確なので、当たったほうだけを言う。
    /// 覆っているときは `hitTest` を聞かずに済むので往復も1つ減る
    /// `insideInAppAlert`: 対象がアプリ内アラート(`AlertTreeScope.frontInAppAlert`)の部分木に居る。そのボタンは
    /// `/hittable` が引き当てられないことがあり(実機 SE3・SwiftUI の `.alert` で 5/5。押せば届いて閉じた)、
    /// 「アプリスイッチャー/別アプリ」と断じて撃ち直しを誘っていた。木がアラートを前面と言っている以上、
    /// 問い合わせ対象が外れたという推論は成り立たないので聞かない(覆いは聞く)
    /// `operation` = 文言の操作名(ft_tap の経路は "tap"。ref のジェスチャは "double tap" / "drag" / "pinch")
    static func screenNotRepresentedWarning(_ found: ElementInfo, nativeRef: Int, otherNativeRefs: [Int], driver: AppDriver,
                                            insideInAppAlert: Bool, operation: String) async -> String {
        let covering = await systemUICoveringWarning(found, driver: driver, operation: operation)
        if !covering.isEmpty { return covering }
        if insideInAppAlert { return "" }
        return await treeDoesNotMatchScreenWarning(found, nativeRef: nativeRef, otherNativeRefs: otherNativeRefs,
                                                   driver: driver, operation: operation)
    }

    /// **`screenNotRepresentedWarning` を毎タップ聞き直さない**。
    /// 撃つ前の照合(`verifiedRef`)は ref のたびに最大3往復(`/systemalert` →
    /// `/systemui/covering` → `/hittable`)を払っており、同じ画面へ連打するだけの探索でも
    /// 木の数だけ払っていた。**撮り直した fresh 木の指紋が前回と同じなら答えを使い回す**——
    /// この探針が答える3つはどれも「今の画面が何か」を言うもので、木がバイト同一のままなら
    /// 答えも変わらない。**ただし要素ごとに使い回す**(同じ要素への連打だけが往復を省く)。
    ///
    /// **健全性の限界(意図した上限)**: 木をバイト同一に保ったまま覆う面が出入りする形
    /// (静止画面の上に Control Center が出た/消えた、等)は、次に木そのものが変わるまで
    /// 再確認しない。見逃しの範囲はそこまでに限られる —— 木が動けば必ず撮り直す
    ///
    /// **アラートはここで聞かない**(`verifiedRef` / `verifiedElement` が毎回聞いて断る。`systemAlertGate` 参照)
    func memoizedScreenProbe(_ found: ElementInfo, fresh: SnapshotResponse,
                             driver: AppDriver, args: [String: Any], operation: String) async -> String {
        let key = Self.sessionKey(args)
        // **要素も鍵に入れる**: 答えには要素ごとに変わるもの(`/hittable`・警告の中の名指し)が
        // 混ざる。木の指紋だけで使い回すと、同じ画面の別の要素へ前の要素の答えが返る(全面の覆いの警告が前の要素を
        // 名指しし、`/hittable` の答えも前の要素のものだった)
        var hasher = Hasher()
        hasher.combine(Self.treeFingerprint(fresh))
        hasher.combine(found.ref)
        hasher.combine(operation)   // 文言が操作名を含む(tap の答えを pinch へ返さない)
        let fingerprint = hasher.finalize()
        if let memo = lastScreenProbe[key], memo.fingerprint == fingerprint {
            return memo.warning
        }
        let insideAlert = AlertTreeScope.frontInAppAlert(in: fresh).map { alert in
            AlertTreeScope.alertOnly(alert, in: fresh).elements.contains { $0.ref == found.ref }
        } ?? false
        let others = fresh.elements.filter { $0.ref != found.ref && !($0.label ?? "").isEmpty && TapTargetGeometry.platformShouldResolve($0) }
            .prefix(2).map { nativeRef($0.ref, args: args) }
        let warning = await Self.screenNotRepresentedWarning(found, nativeRef: nativeRef(found.ref, args: args), otherNativeRefs: others,
                                                             driver: driver, insideInAppAlert: insideAlert,
                                                             operation: operation)
        lastScreenProbe[key] = (fingerprint, warning)
        return warning
    }

    /// **SpringBoard のアラートが前面に出ていることを名指しする**(iOS xcuitest だけ)。
    ///
    /// DSL 側は `SystemUIGate` + `StepExecutor.unregisteredSystemAlert` で同じ判定をしている
    /// (CLAUDE.md「システムアラートの判定は2段」)。MCP には launch 系ツールしか呼ばず、
    /// この関数自体は判定を持たない(`SystemUIGate.isCovered`/`describeUnregistered` を転送する
    /// だけ)—— 判定は1箇所、文言はここ。
    ///
    /// **NoteCatalog の対象外**: あちらは木だけから決まる注記の唯一の定義元だが、これは
    /// 木の外(`/systemalert`)からの申告で、`backgroundNote`/`switchedNote` と同じ扱い
    /// (NoteCoverageTests.testSnapshotBodyEmitsOnlyCatalogNotes がこの形を許容している)。
    ///
    /// **呼び出し元が2つ**: `snapshotBody` は `systemAlertProbePending` が立っているときだけ
    /// (launch 直後の1回)、ref 操作の経路は `systemAlertGate` として毎回
    /// (費用は MCP の ref 操作だけ)。答えられない(旧ブリッジ・Android。inapp-boost モードは XCUITest ブリッジ側へ
    /// 聞く)/ 出ていないときは黙る
    static func systemAlertNote(driver: AppDriver) async -> String {
        guard let what = await frontSystemAlert(driver: driver) else { return "" }
        return "note: \(what) is in front of the app. The app's element list is left out while it is up —"
            + " nothing in the app can be reached until the alert is closed, and the alert is drawn by"
            + " SpringBoard so it never appears in the list. \(handleAlertFirst)."
    }

    /// 操作の後なのに木が前の世代と同じ(= 最新世代の操作数が今のセッションの操作数より古い)とき、前面のシステムアラートを聞くか。
    /// iOS だけ(Android は覆いが木に載る)。同じ操作数では1回だけ(`probedAtActionCount`)= 何も変えない手の後に ft_snapshot を
    /// 重ねても往復を払い続けない。launch 系の予約(`systemAlertProbePending`)とは別の入口で、どちらでも聞けば答えは同じ
    static func shouldProbeAfterUnchangedTree(isAndroid: Bool, lastGenerationActionCount: Int?,
                                              sessionActionCount: Int, probedAtActionCount: Int?) -> Bool {
        guard !isAndroid, let generation = lastGenerationActionCount else { return false }
        return sessionActionCount > generation && probedAtActionCount != sessionActionCount
    }

    /// **中心がソフトキーボードの下にある要素への ref 操作は断る**(ユーザー決定)。
    /// ghost・重なりは「拒否せず警告して撃つ」だが、キーボード被覆は**結果が確実で副作用がある**:
    /// XCUITest はキーの上に指が落ちて**焦点の欄に文字が入り**(実機 SE3・`#tab_about` で「o」)、
    /// in-app は 422 で断る = ブリッジで割れていた。判定は ref 形・DSL と同じ `KeyboardOcclusion`
    /// (chrome 自身とその部分木は除外済み)。**座標形は断らない**(キーを押す意図があり得る。
    /// `keyboardCoordinateWarning`)。DSL の tap は据え置き(注記のみ)
    static func keyboardRefusal(_ target: ElementInfo, keyboardOcclusion: KeyboardOcclusion,
                                tree: [ElementInfo], isAndroid: Bool) -> String? {
        guard let advisory = keyboardOcclusion.advisory(for: target) else { return nil }
        if typesWithoutTouching(target, in: tree) { return nil }
        // 断る理由はプラットフォームごとの事実だけを言う(Android に XCUITest の説明を出さない)
        let consequence = isAndroid
            ? "A touch there would land on the keyboard, not on the element."
            : "The finger would press a key and type into the focused field."
        return "refusing to act on \(RefGuard.describe(target)): \(advisory). \(consequence)"
            + " Close the keyboard with ft_hide_keyboard (it sends no Enter; ft_navigate back on Android), or"
            + " ft_scroll_to the element, then take a fresh ft_snapshot. ft_type pressEnter: true also closes it"
            + " on some screens but fires the field's action, and in a multiline field it adds a newline instead"
    }

    /// **いま焦点を持つ欄への ft_type / ft_clear_input は、ドライバがタップせずに打つ**(DSL の reachPastKeyboard と同じ)。
    /// キーボードの下・細い帯に潰れた・せり上がったバーの下でも触らないので、断りも「タップがキーボードに当たる」警告も出さない
    /// (`keyboardRefusal` / `keyboardCoverRefusal` / `RefGuard.preTapWarnings` が共有する1箇所)
    static func typesWithoutTouching(_ target: ElementInfo, in tree: [ElementInfo]) -> Bool {
        (currentTool == "ft_type" || currentTool == "ft_clear_input") && InputFocusRescue.holdsFocus(target, in: tree)
    }

    /// **ref の経路も座標の経路と同じく、中心が画面の上の外なら撃たずに断る**(`offscreenCoordinateError` の上の外と同じ判定
    /// `TapTargetGeometry.isPointAboveScreen`。撃つとステータスバーが押され、一覧が先頭へ戻って別の画面になる)。下・横の外は従来どおり
    /// 警告して撃つ(探索が動かせる)。ref を引く全経路(`verifiedRef` と `refGestureGuard`)が呼ぶ
    static func aboveScreenRefusal(_ found: ElementInfo, screen: FTRect, label: String) -> String? {
        if let pinned = RefGuard.originPinnedRefusal(found, screen: screen, label: label) { return pinned }  // 原点に貼り付いた枠(DR-203)
        guard TapTargetGeometry.centreIsAboveScreen(found, screen: screen) else { return nil }
        return "refusing \(label): \(RefGuard.describe(found))'s centre (\(Int(saturating: found.frame.centerX)), \(Int(saturating: found.frame.centerY)))"
            + " is above the top of the screen (y < \(Int(saturating: screen.y))) — a touch there lands on the status bar"
            + " (which scrolls the list back to its top), not on the element. Nothing was sent."
            + " ft_scroll_to it (or swipe the other way), then take a fresh ft_snapshot and use the new ref"
    }

    /// `PreFireGuard.keyboardCover` の断り(ref を引く全経路 = `verifiedRef` と `refGestureGuard` が呼ぶ)
    static func keyboardCoverRefusal(_ found: ElementInfo, in tree: SnapshotResponse,
                                     keyboardOcclusion: KeyboardOcclusion, label: String) -> String? {
        guard let cover = PreFireGuard.keyboardCover(of: found, in: tree, keyboard: keyboardOcclusion),
              !typesWithoutTouching(found, in: tree.elements) else { return nil }
        let why: String
        switch cover {
        case .raisedBar(let bar): why = "covered by \(RefGuard.describe(bar)), which rose above the keyboard"
        case .collapsed: why = "collapsed to a thin band (\(Int(saturating: found.frame.width))x\(Int(saturating: found.frame.height)))"
        }
        return "refusing \(label): \(RefGuard.describe(found)) is \(why)"
            + " while the on-screen keyboard is up, so a touch would not land on it. Nothing was sent."
            + " Close the keyboard (ft_hide_keyboard), take a fresh ft_snapshot and use the new ref"
    }

    /// **システムアラートが前面にある間、ref の操作は断る**(ref 操作 = ft_tap / ft_type / ft_clear_input /
    /// ft_long_press / ft_batch の1手目 = `verifiedRef`、ft_double_tap / ft_drag / ft_pinch = `verifiedElement`。
    /// **ref を座標に畳む経路も同じ門を通す** —— 畳んだ先は座標の操作だが、ref で指した以上アラートの
    /// 下のアプリの要素が狙いなので、座標形の「アラートそのものを叩く正当な操作」には当たらない)。警告にとどめないのは、
    /// どちらのブリッジでも操作が届き、起きることが取り返しにくいため(実測):
    /// in-app はアプリのプロセス内で activate / 合成タッチを撃つのでアラートを残したまま背面のアプリが反応し、
    /// XCUITest は XCTest 自身の割り込み処理がアラートのボタン(拒否側)を押してから通すので権限を黙って変える。
    /// **断らないもの**: 座標の操作(XCUITest ではアラートそのものに当たる正当な操作)・DSL(`SystemUIGate` の
    /// 2段の規律が別にある)。SpringBoard に attach している間は呼び手が呼ばない(アラートのボタンを押す経路)
    ///
    /// **照会そのものが失敗したら断らずに撃つが、確かめていないことを注記に残す**(`.proceed(note:)`)。
    /// 失敗を「出ていない」と同じ nil に畳むと、USB の token 無し・WiFi の待ち受け断・ランナーの死亡で
    /// 門が黙って開く(P2 と同型。DSL は `StepExecutor.probeSystemAlert` が同じ規律で注記を立てる)
    enum SystemAlertGate {
        case refuse(String)
        /// note は空か " note: …"(`verifiedRef` の staleNote と同じ形 = 先頭に空白・末尾に余白なし)
        case proceed(note: String)
    }

    static let performingActionPhase = "performing the action"

    static func systemAlertGate(_ target: ElementInfo, driver: AppDriver,
                                bridge: String?) async -> SystemAlertGate {
        let probe: SystemAlertProbeResponse?
        SlowCallWatchdog.mark("probing for a system alert")
        switch await driver.systemAlert() {
        case .value(let answer): probe = answer
        case .notAnswerable: probe = nil
        case .failed(let reason):
            return .proceed(note: " note: the system-alert check before acting on"
                + " \(RefGuard.describe(target)) failed (\(reason)), so the"
                + " action went ahead without knowing whether an alert was in front of the app —"
                + " if the screen did not respond, check for an alert with"
                + " `ft_launch bundleId: com.apple.springboard`.")
        }
        guard let what = Self.describeFrontSystemAlert(probe) else { return .proceed(note: "") }
        let consequence: String
        switch bridge {   // MCP の iOS は常に XCUITest(in-app ブリッジの帰結は起きない)
        case "xcuitest":
            consequence = "XCTest would handle the alert on its own first and can press one of its"
                + " buttons (observed: the deny button), silently changing the permission"
        default:
            consequence = "what the tool would do to the alert depends on the bridge"
        }
        return .refuse("refusing to act on \(RefGuard.describe(target)): \(what) is in front of the app,"
            + " so a finger would land on the alert — \(consequence). \(handleAlertFirst).")
    }

    private static let handleAlertFirst = "Handle the alert first: `ft_tap alertButton: \"<button>\"`"
        + " presses one of its buttons and returns to your app — pass alertButton with this same call to press it and then act, in one call"

    /// 座標の ft_tap は ref の門(アラートの確認)を通らないので、ブリッジがアラートで届けずに断った 422
    /// (`DriverError.systemAlertBlocked`)に、ref の門と同じ出口をここで足す(ブリッジの本文はシナリオ向けで iosAlertHandler しか言わない)
    static func systemAlertBlockedHint(_ error: Error) -> String {
        guard case DriverError.systemAlertBlocked? = error as? DriverError else { return "" }
        return "\n" + handleAlertFirst + "."
    }

    /// ランナーの 422(別のアプリが前面・システムアラートが前面)が、実は SpringBoard の覆い(通知センター・スイッチャー等)
    /// によるものかを聞いて、ft_status と同じ面の名前で言い直す(iOS だけ)。ランナーの文言は固定で覆いを知らない
    /// (「another app is」「system alert … tap one of its buttons」)ので、**呼び手が覆いの事実を足す**。
    /// 聞いて覆いが無い・聞けない・422 以外の失敗は空(元の文言のまま)。失敗経路の1回だけ(毎手の照会ではない)
    func coveredDriverErrorHint(_ error: Error, args: [String: Any]) async -> String {
        guard let driverError = error as? DriverError, connectedPorts[Self.sessionKey(args)] != nil else { return "" }
        switch driverError {
        case .badResponse(let status, _) where status == 422: break
        case .systemAlertBlocked: break
        default: return ""
        }
        guard let covered = try? await self.driver(args),
              case .value(let surface?) = await ForegroundState.coveringProbe(covered) else { return "" }
        return Self.coveredRefusalNote(surface)
    }

    static func coveredRefusalNote(_ surface: CoveringSurface) -> String {
        "\nnote: SpringBoard reports \(coveringSurfaceName(surface)) drawn over the app right now — that is what this refusal"
            + " is about, not a different app and not an alert to answer by pressing its buttons (anything that looks like"
            + " a button there belongs to that surface). Dismiss it first (swipe up from the bottom edge, or ft_navigate home),"
            + " then ft_snapshot; ft_launch the bundleId with resume: true if the app is not back."
    }

    // **internal**(MCPServer+ScreenTools.swift の ft_type ref なし失敗経路も使う。他ファイルの
    // 拡張から呼ぶので private のままにできない)。一発物の照会 = target 無しで前面のアラートだけ聞く
    static func frontSystemAlert(driver: AppDriver) async -> String? {
        describeFrontSystemAlert(await driver.systemAlert().value)
    }

    private static func describeFrontSystemAlert(_ probe: SystemAlertProbeResponse?) -> String? {
        SystemUIGate.frontAlertPhrase(probe)
    }

    /// **SpringBoard の面がアプリを覆っている**ことを SpringBoard に聞く(iOS xcuitest だけ)。
    ///
    /// `treeDoesNotMatchScreenWarning` では拾えない形を埋める —— コントロールセンター /
    /// 通知センターはアプリを前面のまま覆うので、木も `XCUIApplication.state` も `/hittable` も
    /// 全部「正常」を返す(実機 iPhone SE3 で実測)。**アプリ側には知る手段が無い**。
    ///
    /// **費用**: `/systemalert` と同じ「目印を1問聞くだけ」の口。**MCP のタップ経路だけ**に置く ——
    /// エージェントは1手ずつ撃つので影響しないが、DSL は1 run で数千回撃つ。DSL へ広げるのは
    /// 実害を観測してから(現時点で DSL での観測は0件)。
    /// **警告のみ**(拒否しない)。答えられない(旧ブリッジ・in-app・Android)ときは黙る
    static func systemUICoveringWarning(_ found: ElementInfo, driver: AppDriver, operation: String = "tap") async -> String {
        guard let covering = await driver.systemUICovering().value, covering.covering
        else { return "" }
        let surface = Self.coveringSurfaceName(CoveringSurface.from(marker: covering.marker))
        return " (warning: \(surface) is drawn over the app right now, so \(RefGuard.describe(found))"
            + " is not actually reachable — the element list still shows what is underneath,"
            + " because the covering surface belongs to another process and never appears in it."
            + " This \(operation) landed on that surface. Dismiss it first, then read the screen again)"
    }

    /// 面の呼び名(ft_status・snapshot の注記・タップ後の警告で共有)
    static func coveringSurfaceName(_ surface: CoveringSurface) -> String {
        surface.displayName
    }

    /// 覆いの注記を出してよい木か。SpringBoard のセッションの木は覆っている面そのもの(アプリの木ではない)
    static func shouldProbeCovering(sessionBundleID: String?) -> Bool {
        sessionBundleID != ForegroundState.springboard
    }

    /// アプリが画面へ戻っていると証拠で言えるか(iOS)。`/appstate` が前面・覆い無し・木の操作できる要素の1つが
    /// ライブのヒットテストで引き当てられた(`hittable(true)`)の3つが揃ったときだけ true。どれかが聞けない・食い違うなら false
    func iosAppIsBackOnScreen(_ snapshot: SnapshotResponse, driver: AppDriver, args: [String: Any]) async -> Bool {
        guard let bundleID = snapshot.sessionBundleID, bundleID != ForegroundState.springboard,
              case .value(true) = await ForegroundState.inForegroundProbe(driver, bundleID: bundleID),
              case .value(nil) = await ForegroundState.coveringProbe(driver),
              let probe = snapshot.elements.first(where: { TapTargetGeometry.platformShouldResolve($0) })
        else { return false }
        return (try? await driver.hitTest(ref: nativeRef(probe.ref, args: args))) == .hittable(true)
    }

    /// 読みの応答に添える「覆われている」注記。iOS XCUITest だけが答える(他は `.notAnswerable` で黙る)。
    /// 費用は `/systemui/covering` の1往復。**呼ぶのは ft_snapshot(1手ずつ読む口)と、操作の直後に木が変わらなかった
    /// snapshotAfter だけ** —— 覆いの下では木が操作の前と1バイト同じままなので「変わらなかった」形が唯一の手がかり。
    /// 毎手の照会は取り消した(約 0.6 秒)ので足さない
    static func coveringNote(driver: AppDriver) async -> String {
        guard case .value(let surface?) = await ForegroundState.coveringProbe(driver) else { return "" }
        return "⚠️ \(coveringSurfaceName(surface)) is drawn over the app right now: the tree below is the app's own tree"
            + " (the covering surface belongs to another process and never appears in it), NOT what is on screen —"
            + " a tap by ref here lands on that surface. Dismiss it first, then read the screen again.\n"
    }

    /// **木が画面を代表していないことを、木の外から知る唯一の答え**(iOS xcuitest だけ)。
    ///
    /// アプリが**問い合わせ対象でなくなった**とき(アプリスイッチャーが開いた・別アプリが前面に
    /// 来た)、`/snapshot` は**直前と1バイト同じ木**を返し続け、`XCUIApplication.state` も
    /// `foreground: true` のままになる(実機・Simulator の両方で実測)。木由来の判定は全部素通しする。
    /// **唯一食い違うのがライブのヒットテスト** —— 木が今まさに載せている要素を引き当てられない。
    ///
    /// 実測(Simulator の設定 root): 覆い無し 0/12 → アプリスイッチャーで 12/12。
    /// 実害の witness は同じ形で `ft_tap` が **`tap [5] done. (selector: #com.apple.settings
    /// .primaryAppleAccount)` と成功を返しながら、実際にはスイッチャーの別アプリのカードに
    /// 当たって端末ごと別アプリへ切り替わった**こと。
    ///
    /// **拾えない形(実測して確定・文言で名乗らないこと)**: **コントロールセンター / 通知センター**は
    /// この信号を出さない —— アプリは前面のまま問い合わせに答え続けるので、全画面を覆われていても
    /// `hittable: true` が返る(Simulator と実機 iPhone SE の両方で確認)。あちらは
    /// **別の手当てが要る未解決の穴**(docs/mcp-audit-rounds.md の当該ラウンド)
    ///
    /// **絞り込みは `TapTargetGeometry.platformShouldResolve`**(名前を持たない容器は覆いが
    /// 無くても引き当てられないので、そのまま信号にすると誤検知だらけになる。実測は同 doc)。
    /// **警告のみ**(拒否しない)。答えられない(旧ブリッジ・in-app・Android)ときは黙る。
    ///
    /// **費用**: 対象1件で 72〜146ms。**MCP のタップ経路だけ**に置く —— こちらは
    /// エージェントが1手ずつ撃つので影響が無い。DSL は1 run で数千回撃つため、
    /// 同じ費用を毎ステップ払う判断は実測してから(今回は入れていない)
    /// `nativeRef` = ブリッジの番号(`found.ref` はセッションの番号 = 最初の世代以外は別の要素を指す)
    /// `otherNativeRefs` = 同じ木の別の要素。どれかが引き当てられたらアプリは問い合わせ対象のまま = 帰属を言わない(連絡先の検索結果の行だけが引き当てられない形。スイッチャーでは全要素 12/12 が引き当てられない)
    static func treeDoesNotMatchScreenWarning(_ found: ElementInfo, nativeRef: Int, otherNativeRefs: [Int],
                                              driver: AppDriver, operation: String = "tap") async -> String {
        guard TapTargetGeometry.platformShouldResolve(found),
              (try? await driver.hitTest(ref: nativeRef)) == .unresolvable
        else { return "" }
        for other in otherNativeRefs {
            if let answer = try? await driver.hitTest(ref: other), answer != .unresolvable { return "" }
        }
        return " (warning: the platform cannot find \(RefGuard.describe(found)) at all, even though"
            + " the tree just listed it — the app is no longer the one being queried (the app"
            + " switcher is open, another app came to the front, or the device's screen is off or locked),"
            + " and the tree still shows what was there before. This \(operation) almost certainly did not reach the app,"
            + " so \"done\" here only means the \(operation) was sent."
            + " Check with ft_screenshot, and bring the app back before operating it)"
    }

    /// ゲートなしでヒットテストだけ聞く。`.hittable(false)` と断言されたときだけ true(答えられない・失敗は黙る)
    static func isReportedNotHittable(nativeRef: Int, driver: AppDriver) async -> Bool {
        (try? await driver.hitTest(ref: nativeRef)) == .hittable(false)
    }

    /// **木では答えられない「上のクロムの下へ潜っているか」をプラットフォームに聞く**(iOS だけ)。
    ///
    /// ゲートは `TapTargetGeometry.suspectedHiddenUnderChrome`(粗くてよい。断定は
    /// ヒットテストに委ねる)。**疑ったときだけ1件聞く** —— 全要素に付けると実測 5.1 秒
    /// = snapshot の 50 倍で、常時は払えない(`AppDriver.hittable` の doc)。
    ///
    /// **答えられないとき(nil)は黙る**: 旧ブリッジ・引き当て不能・Android はすべてここ。
    /// 木の限界を別の推測で置き換えないため、`false` と断言されたときだけ言う
    /// `nativeRef` = ブリッジの番号(`found.ref` はセッションの番号 = 最初の世代以外は別の要素を指す)
    static func hiddenUnderChromeWarning(_ found: ElementInfo, nativeRef: Int, in fresh: SnapshotResponse,
                                         driver: AppDriver) async -> String {
        guard TapTargetGeometry.suspectedHiddenUnderChrome(found, in: fresh.elements,
                                                           screen: fresh.screen),
              (try? await driver.hitTest(ref: nativeRef)) == .hittable(false)
        else { return "" }
        return " (warning: the platform reports \(RefGuard.describe(found)) is NOT hittable at its"
            + " reported position — it is scrolled under the navigation bar or another overlay, so"
            + " this tap most likely landed on whatever is drawn there. Scroll it into view first)"
    }

    /// ref を撃つ直前の照合。**撮り直した木から同じ要素を引き直して、その新しい ref を返す**。
    /// 引けない(消えた・ghost)なら撃たずに throw する —— 沈黙した誤操作を作らないため。
    ///
    /// **このセッションが1つも撮っていない**(`nextRefBase == 0`)ときは撮ってから引く(`verifiedElement` と同じ)。
    /// 素通しにしていた頃は、launch で空になったブリッジの番号表に当たって HTTP の 404 がそのまま出た。
    /// **どの世代にも無い ref**(何か撮った後で、それでも一致しない番号)は throw する
    /// —— セッション内で ref は一意なので、世代があるのに見つからないのは番号の書き間違いか、
    /// 直近5世代より前の snapshot からコピーしてきた番号のどちらか。
    ///
    /// **世代の有無はセッション全体で見る**(実機+仮想デバイス混在の監査)。
    /// 「この sessionKey に世代が無いか」だけで判定すると、sessionKey は**指し方**込み
    /// (`profile:<project>:<name>` / `direct:ios:<port>:`)なので、**同じ機を profile: で撮って
    /// port: で撃つ**だけで「世代なし」になり、番号がそのままブリッジへ渡ってしまう。
    /// ブリッジは自前の 1..N で解決するので**別の要素に当たって成功と報告する** ——
    /// 実機で再現: profile: で撮った木の ref は 70..93 なのに `port:8143 ref:10` が
    /// `tap [10] done` を返し、ブリッジの #10 = `#btn_input_submit` を実際に押した
    /// (`submitted=-` → `submitted=physical`)。
    /// 返す ref は**セッション ref**(ブリッジへ渡す前に呼び手が `nativeRef` を通すこと)
    func verifiedRef(_ ref: Int, driver: AppDriver,
                             args: [String: Any], operation: String, keyboardClosed: Bool = false) async throws -> (ref: Int, note: String) {
        sessions[Self.sessionKey(args), default: DeviceSession()].refRetarget = nil
        var sessionRef = resolveSessionRef(ref, args: args)
        // 撮ってから引いた木。下の「撃つ直前の読み直し」はこれを使う(間に操作が無いので読み直しと同じ = 2枚払わない)。
        // selector で指した呼び出しは解決に使った木を預けている(DeviceSession.selectorJustRead)
        var justRead: SnapshotResponse? = sessions[Self.sessionKey(args)]?.selectorJustRead
            .flatMap { tree in tree.elements.contains(where: { $0.ref == ref }) ? tree : nil }
        sessions[Self.sessionKey(args), default: DeviceSession()].selectorJustRead = nil
        if sessionRef == nil, nextRefBase == 0 {
            // **1つも撮っていない = 撮ってから引く**(verifiedElement と同じ)。素通しすると、launch で空になった
            // ブリッジの番号表に当たって HTTP の 404(「Run GET /snapshot first」)がそのまま出た
            let fresh = try await freshSnapshot(driver, args: args)
            guard fresh.elements.contains(where: { $0.ref == ref }) else {
                throw MCPError("unknown ref [\(ref)]. Take an ft_snapshot first")
            }
            sessionRef = resolveSessionRef(ref, args: args)
            justRead = fresh
        }
        guard let resolved = sessionRef else {
            if let owner = otherKeyHolding(ref, args: args) {
                throw MCPError(Self.refFromAnotherTargetMessage(
                    ref: ref, takenUnder: owner, firedAt: Self.sessionKey(args),
                    udid: (args["udid"] as? String).flatMap { $0.isEmpty ? nil : $0 }))
            }
            throw MCPError("unknown ref [\(ref)] — it is not from any recent snapshot"
                + " (refs are per-snapshot; the last 5 snapshots were checked)."
                + " Take a fresh ft_snapshot")
        }
        let target = resolved.element
        // **isStale の注記を先頭に置く**: 何に当たったかの前に、番号の出所が古いことを言う
        // **先頭は空白・末尾に余白を残さない**(RefGuard の警告群と同じ形。ここだけ裸の
        // "note:" で始まると "done.note:" と密着し、末尾空白は次の " (selector:" と二重になる)
        let staleNote = resolved.isStale
            ? " note: [\(ref)] is from an older snapshot (refs have been renumbered since)."
                + " It was matched as \(RefGuard.describe(target)) and re-located in the current"
                + " tree — prefer refs from the latest snapshot."
            : ""
        let takenFrom = generationSnapshot(containing: ref, args: args)
        let lastRendered = takenFrom?.elements ?? []
        var fresh: SnapshotResponse
        if let justRead {
            fresh = justRead
        } else {
            SlowCallWatchdog.mark("re-reading the tree to check ref [\(ref)]")
            fresh = try await freshSnapshot(driver, args: args)
        }
        fresh = try await consumePendingTypeKeyboardCheck(fresh, driver: driver, args: args)
        if let message = Self.refFromAnotherAppMessage(
            ref: ref, takenFrom: takenFrom, fresh: fresh) { throw MCPError(message) }
        let key = Self.sessionKey(args)
        var probeNote = ""
        if launchedBundleIDs[key] != "com.apple.springboard" {
            switch await Self.systemAlertGate(target, driver: driver, bridge: bridges[key]) {
            case .refuse(let refusal): throw MCPError(refusal)
            case .proceed(let note): probeNote = note
            }
        }
        // **ここから先は操作そのもの**(打たないと操作の時間が直前の「確認」の段に積まれ、Android にも
        // 「probing for a system alert 9.2s」と出ていた = 計測で誤読した)
        SlowCallWatchdog.mark(Self.performingActionPhase)
        // **ref の出所についての注記はまとめて先頭に置く**(何に当たったかより前に言う)。
        // 2つは排他 —— screenChangedUnderRefNote は isStale のとき黙る
        let actedSinceTakenFrom = (sessionActionCounts[Self.sessionKey(args)] ?? 0)
            > (generationActionCount(containing: ref, args: args) ?? 0)
        let takenRightAfterOwnAction = generationFollowsOwnAction(containing: ref, args: args)
        let screenChangedNote = Self.screenChangedUnderRefNote(
            ref: ref, takenFrom: takenFrom, fresh: fresh,
            isStale: resolved.isStale, matched: target, actedSinceTakenFrom: actedSinceTakenFrom,
            takenRightAfterOwnAction: takenRightAfterOwnAction,
            loadingNoteShownBefore: loadingRefNoteShown.contains(key))
        // 「操作の直後の読み」の分岐で言ったときだけ立てる(その分岐の条件と同じ)
        if !screenChangedNote.isEmpty, takenRightAfterOwnAction, !actedSinceTakenFrom {
            loadingRefNoteShown.insert(key)
        }
        let originNote = staleNote + probeNote + screenChangedNote + refFrontAppNote(fresh, args: args)
        // **申告 keyboardFrame はキー面だけ**(サジェストバー・地球儀/Dictate 行を含まない)。木の chrome で広げ、chrome 自身とその部分木は除外する
        // (KeyboardOcclusion の doc)。DSL 側(StepExecutor+Actions.swift)も同じ型で揃える —— 片方だけ広げると MCP と DSL が同じ画面で違う判断をする
        let keyboardOcclusion = KeyboardOcclusion.resolve(reported: fresh.keyboardFrame, in: fresh.elements, screen: fresh.screen)
        // **木に出ないオーバーレイ・ウィンドウ**(Android のポップアップ)。keyboardFrame と
        // 同じく申告からしか言えない —— 覆っている実体が fresh.elements に1要素も載らない
        let overlayWindows = OverlayWindowOcclusion.resolve(reported: fresh.overlayWindowFrames)
        let outcome = RefGuard.relocate(target, in: fresh.elements, screen: fresh.screen)
        // **付け替えの判定は ghost も .found も1つの口**(`RefGuard.retargetOutcome`。verifiedElement・scrollFrame の ref と共通)
        let retarget = try Self.retargetNote(outcome, ref: ref, target: target, fresh: fresh.elements,
                                             taken: lastRendered, ownActionSince: actedSinceTakenFrom,
                                             selector: Self.counterpartSelector(fresh))
        switch outcome {
        case .gone:
            throw MCPError(RefGuard.goneMessage(ref: ref, target: target,
                                                truncatedCount: fresh.truncatedCount,
                                                keyboardShown: KeyboardWait.isShown(fresh),
                                                inAppAlert: Self.frontInAppAlertWithButtons(fresh),
                                                currentCounterpart: Self.counterpartClause(for: target, in: fresh)))
        case .ghost(let found):
            // **拒否せず警告して撃つ**(理由は RefGuard の宣言)。**キーボード被覆だけは断る**(`keyboardRefusal` の doc)
            if let refusal = Self.keyboardRefusal(found, keyboardOcclusion: keyboardOcclusion,
                                                      tree: fresh.elements, isAndroid: Self.platformName(args) == "android") {
                if let reached = try await refAfterClosingKeyboard(ref, driver: driver, args: args, operation: operation, closedAlready: keyboardClosed) { return reached }
                throw MCPError(refusal)
            }
            if let refusal = Self.aboveScreenRefusal(found, screen: fresh.screen, label: "[\(ref)]") {
                throw MCPError(refusal)
            }
            return (found.ref, originNote + retarget
                + RefGuard.preTapWarnings(found, keyboardOcclusion: keyboardOcclusion,
                                        suppressKeyboardWarning: Self.typesWithoutTouching(found, in: fresh.elements),
                                        overlayWindows: overlayWindows,
                                        safeAreaTop: fresh.safeAreaTop, screen: fresh.screen)
                + RefGuard.ghostWarning(found: found, in: fresh.elements, screen: fresh.screen))
        case .found(let found, let moved):
            if let refusal = Self.keyboardRefusal(found, keyboardOcclusion: keyboardOcclusion,
                                                      tree: fresh.elements, isAndroid: Self.platformName(args) == "android") {
                if let reached = try await refAfterClosingKeyboard(ref, driver: driver, args: args, operation: operation, closedAlready: keyboardClosed) { return reached }
                throw MCPError(refusal)
            }
            // **キーボードで枠が細い帯に潰れた・せり上がったバーに覆われた対象は撃たない**(DSL は閉じてから撃つ。判定は `PreFireGuard`)
            if let refusal = Self.keyboardCoverRefusal(found, in: fresh, keyboardOcclusion: keyboardOcclusion,
                                                       label: "[\(ref)]") {
                throw MCPError(refusal)
            }
            if let refusal = Self.aboveScreenRefusal(found, screen: fresh.screen, label: "[\(ref)]") {
                throw MCPError(refusal)
            }
            let labelNote = retarget
            // **ghost でなくても別の物に当たり得る**2形(上に描かれた overlay / 同一矩形への
            // 積み重なり)。どちらも容器の内側なので RefGuard.relocate では .found になる
            let overlap = originNote
                + RefGuard.preTapWarnings(found, keyboardOcclusion: keyboardOcclusion,
                                        suppressKeyboardWarning: Self.typesWithoutTouching(found, in: fresh.elements),
                                        overlayWindows: overlayWindows,
                                        safeAreaTop: fresh.safeAreaTop, screen: fresh.screen)
                + RefGuard.overlapWarning(found: found, in: fresh.elements, screen: fresh.screen,
                                        isAndroid: Self.platformName(args) == "android", operation: operation)
                // 貼り付く見出しの下(DSL は送って外す。判定は TapTargetGeometry.pinnedBandNote)
                + (TapTargetGeometry.pinnedBandNote(for: found, in: fresh.elements, operation: "touch") ?? "")
                + (await Self.hiddenUnderChromeWarning(found, nativeRef: nativeRef(found.ref, args: args),
                                                       in: fresh, driver: driver))
                // SpringBoard に attach している間は「面がアプリを覆っている」系の注記を出さない
                // —— その面(許可アラート等)のボタンを撃っている最中に「SpringBoard へ attach して
                // 読め」と言うことになる(実機 iPhone 13 で実際に出た)
                + (launchedBundleIDs[Self.sessionKey(args)] == "com.apple.springboard" ? ""
                    : await memoizedScreenProbe(found, fresh: fresh, driver: driver, args: args, operation: operation))
            // **容器の縁にまたがる行**(DSL は内側へ寄せてから撃つ。MCP は ref を撃つだけなので警告する)。
            // 判定は DSL と共有(`TapTargetGeometry.straddlingContainerEdge`)
            let straddle = Self.straddleWarning(found, in: fresh.elements, operation: operation)
            guard moved >= RefGuard.movedThreshold else {
                return (found.ref, overlap + straddle + labelNote)
            }
            // **原因までは断定できない**が、「他も同じだけ動いたか」は手元の2枚から言える。
            // 揃って動いていればスクロール等の画面全体の移動、その要素だけならレイアウト変化。
            // 切り分けの手掛かりとして出す(外部フィードバック。severity は低いとのこと)
            let cause = RefGuard.movedTogether(target, found,
                                               before: lastRendered, after: fresh.elements,
                                               ownActionSince: actedSinceTakenFrom)
            // **動いた後の位置にも同じ警告を全部付ける**(`overlap` = 画面外・覆い・貼り付く見出し・ヒットテスト。
            // 動いた経路だけ省くと、付け替えた先の中心が画面の外でも無警告になっていた)
            let movedNote = RefGuard.movedNote(found: found, moved: moved, cause: cause,
                                               unit: Self.platformName(args) == "android" ? "px" : "pt")
            sessions[key, default: DeviceSession()].refRetarget = (found.ref, movedNote.trimmingCharacters(in: .whitespaces))
            return (found.ref, overlap + movedNote + straddle + labelNote)
        }
    }

    /// 縁またぎの警告(ref を引く全経路 = `verifiedRef` と `refGestureGuard` が呼ぶ。文言は操作名で言う)
    static func straddleWarning(_ found: ElementInfo, in elements: [ElementInfo], operation: String) -> String {
        TapTargetGeometry.straddleAdvisory(for: found, in: elements, operation: operation)
            .map { " (warning: \(RefGuard.describe(found)): \($0))" } ?? ""
    }

    /// 断りに添える「今の木での同じ素性の相手」の節(`RefGuard.currentCounterpartClause`。セレクタは ft_tap の推奨と同じ graded)
    static func counterpartClause(for target: ElementInfo, in fresh: SnapshotResponse) -> String {
        RefGuard.currentCounterpartClause(for: target, in: fresh.elements, selector: counterpartSelector(fresh))
    }

    static func counterpartSelector(_ fresh: SnapshotResponse) -> (ElementInfo) -> String? {
        { SelectorNaming(fresh).graded(for: $0, in: fresh)?.selector }
    }

    /// ref の付け替えの断り(throw)と注記。`verifiedRef` / `verifiedElement` / scrollFrame の ref が通る**唯一の口**
    /// (`TapRefGuardTests` が3箇所の呼び出しを数える)。`.gone` は呼び手が断る
    static func retargetNote(_ outcome: RefGuard.Outcome, ref: Int, target: ElementInfo, fresh: [ElementInfo],
                             taken: [ElementInfo], ownActionSince: Bool,
                             selector: (ElementInfo) -> String?) throws -> String {
        let found: ElementInfo
        switch outcome {
        case .gone: return ""
        case .found(let element, _), .ghost(let element): found = element
        }
        let result = RefGuard.retargetOutcome(ref: ref, target: target, found: found, in: fresh,
                                              taken: taken, ownActionSince: ownActionSince, selector: selector)
        if let refusal = result.refusal { throw MCPError(refusal) }
        return result.note
    }
}

extension MCPServer {
    /// settle-lite の1回の読み直し(`settleWaitSeconds` だけ待って撮る)
    func rereadAfterGrace(_ driver: AppDriver, args: [String: Any]) async throws -> SnapshotResponse {
        try await Task.sleep(nanoseconds: UInt64(max(0, settleWaitSeconds) * 1_000_000_000))
        return try await freshSnapshot(driver, args: args)
    }
}
