// MCPServer+ScrollTools.swift
// ft_scroll_to と、ft_scroll_to / ft_swipe が共有する scrollFrame 引数の解決。木の取得・ref の鮮度は MCPServer+Snapshot.swift

import Foundation
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore

extension MCPServer {
    /// `scrollFrame` 引数の解決結果。**ref(整数)は rect へ、文字列は locator へ**
    /// (FlowStep.scrollFrameRect 参照)。`original` は ref 経由のときだけ埋まり、
    /// シート展開後に同じ要素を撮り直した木から再照合して rect を作り直すのに使う
    /// **ft_scroll_to と ft_swipe が共有する**(解決の2つ目の実装を作らない)
    struct ScrollFrameArg {
        var locator: FlowLocator?
        var rect: FTRect?
        var original: ElementInfo?
        var note: String = ""
        /// 解決した枠が `scrollable` を申告しているか。nil = 確かめられない(セレクタ文字列で渡された枠)
        var declaresScrollable: Bool?
    }

    /// **型は入口で確かめる**(レビュー指摘): resolveScrollFrameArg が見るのは
    /// Int と String だけなので、それ以外(bool・配列・オブジェクト)は空の ScrollFrameArg に
    /// なり、**容器を無視した全画面の操作を「inside …」と名乗って**返す。ft_swipe と ft_scroll_to の
    /// 両方が resolveScrollFrameArg より前(ドライバ取得より前)に呼ぶ —— 片方だけに置くと
    /// もう片方が素通しする(実際に ft_scroll_to が漏れていた)
    static func validateScrollFrameArg(_ args: [String: Any]) throws {
        if let frame = args["scrollFrame"], !(frame is Int), !(frame is String) {
            throw MCPError("scrollFrame must be a selector string (e.g. \"#list_rows\") or an"
                + " ft_snapshot ref (an integer)")
        }
        // 構文検査も型検査と同じ入口(ドライバ取得より前)で —— resolveScrollFrameArg 側の
        // 検査だけだと ft_swipe/ft_scroll_to の driver(args) を先に払ってしまう
        if let text = args["scrollFrame"] as? String {
            if let error = FTSelector.scrollFrameLocator(text).error { throw MCPError("scrollFrame: \(error)") }
        }
    }

    /// **ref はセレクタが書けない容器のための逃げ道**(id の重複・欠落)。
    /// 既存の stale-ref 再照合(resolveSessionRef → RefGuard.relocate)を通してから frame を取る ——
    /// verifiedRef と同じ規律で、撮った時点から動いていても黙って古い座標を使わない
    func resolveScrollFrameArg(_ args: [String: Any], driver: AppDriver) async throws
        -> ScrollFrameArg {
        // **intArgument を通さない**(NumericArgumentSourceScanTests の allowlist 対象): scrollFrame は
        // Int(ref)/String(selector) のどちらも正当な値で、非 Int は「型が違う」のではなく
        // 「もう一方の形」。型の拒否は入口の validateScrollFrameArg(Int/String 以外だけ断る)が
        // 既にやっている
        if let ref = args["scrollFrame"] as? Int {
            guard let resolved = resolveSessionRef(ref, args: args) else {
                throw MCPError("scrollFrame ref [\(ref)] is unknown — it is not from any recent"
                    + " snapshot (refs are per-snapshot; the last 5 snapshots were checked)."
                    + " Take a fresh ft_snapshot")
            }
            let target = resolved.element
            let takenFrom = generationSnapshot(containing: ref, args: args)
            let fresh = try await freshSnapshot(driver, args: args)
            // **ref を食う3つ目の経路**(掃討漏れ)。verifiedRef / verifiedElement /
            // ここ、で全部。容器の ref も id・ラベルで再照合されるので、放置すると
            // **別アプリの同名容器の中でジェスチャが走る**
            if let message = Self.refFromAnotherAppMessage(
                ref: ref, takenFrom: takenFrom, fresh: fresh) { throw MCPError(message) }
            let outcome = RefGuard.relocate(target, in: fresh.elements, screen: fresh.screen)
            let retarget = try Self.retargetNote(
                outcome, ref: ref, target: target, fresh: fresh.elements, taken: takenFrom?.elements ?? [],
                ownActionSince: (sessionActionCounts[Self.sessionKey(args)] ?? 0)
                    > (generationActionCount(containing: ref, args: args) ?? 0),
                selector: Self.counterpartSelector(fresh))
            switch outcome {
            case .gone:
                throw MCPError(RefGuard.goneMessage(ref: ref, target: target,
                                                    truncatedCount: fresh.truncatedCount,
                                                keyboardShown: KeyboardWait.isShown(fresh),
                                                inAppAlert: Self.frontInAppAlertWithButtons(fresh),
                                                currentCounterpart: Self.counterpartClause(for: target, in: fresh)))
            case .ghost(let found), .found(let found, _):
                // **rect にできない容器を黙って渡さない**: 幅か高さが0だと、これを起点にした
                // ジェスチャは1px も動かせる場所を持たない
                guard found.frame.width > 0, found.frame.height > 0 else {
                    throw MCPError("scrollFrame ref [\(ref)] \(RefGuard.describe(found)) has a"
                        + " zero-size frame, so there is nothing to swipe inside")
                }
                var note = retarget
                // 行(自身は scrollable でない)は中身と一緒に動くので、収める容器を払う(判定は DSL の探索と共有)
                let swipeArea = ScrollFrameResolution.enclosingScrollable(of: found, in: fresh.elements, vertical: !["left", "right"].contains((args["direction"] ?? args["finger"]) as? String ?? "down")) ?? found
                if swipeArea.ref != found.ref { note += " — " + ScrollFrameResolution.enclosingScrollableNote(frame: "[\(ref)]", container: swipeArea) }
                // **ref はどんな要素の frame も掴める**(scrollable 申告を確かめない = id の重複・欠落で選べない容器の逃げ道)。
                // 黙って撃つと「マークされた容器の中を振った」と誤読させるので、申告が無いときは出所を名乗る
                if swipeArea.scrollable != true {
                    note += Self.scrollFrameNotDeclaredScrollableNote(swipeArea)
                }
                // **id が一意なら矩形でなく `#id` で渡す**(DSL のシナリオと同じ形 = 1本ごとに今の木で引き直し、消えれば止まる)。
                // 矩形は探索の途中で容器が動いても追従しない(scrollFrameLocator の doc)。一意でなければ従来の矩形
                if let locator = Self.scrollFrameLocator(for: swipeArea, in: fresh) {
                    return ScrollFrameArg(locator: locator, original: swipeArea.ref == found.ref ? target : swipeArea, note: note, declaresScrollable: swipeArea.scrollable == true)
                }
                return ScrollFrameArg(rect: swipeArea.frame, original: swipeArea.ref == found.ref ? target : swipeArea, note: note, declaresScrollable: swipeArea.scrollable == true)
            }
        }
        if let text = args["scrollFrame"] as? String {
            let resolved = FTSelector.scrollFrameLocator(text)
            if let error = resolved.error { throw MCPError("scrollFrame: \(error)") }
            return ScrollFrameArg(locator: resolved.locator)
        }
        return ScrollFrameArg()
    }

    /// シート展開救済の高さ計測(sheetExpansionGrew / sheetShrunkAfterRetry の入力)。
    /// ref 形式は同じ要素を再照合、セレクタ形式は DSL と同じ照合(`ScrollFrameResolution`)で測る。
    /// scrollFrame 未指定なら nil = 判定は黙る(sheetExpansionGrew 側の宣言参照)
    /// ref で渡された容器を**矩形ではなく `#id` で渡す**(id がその画面で一意で、作ったセレクタが同じ要素に当たるときだけ。
    /// 無ければ nil = 矩形のまま)。矩形は探索の途中で容器が動いても追従せず、消えても止まらない(`scrollFrameUnresolved` は
    /// セレクタにしか効かない)= DSL のシナリオ(容器はセレクタでしか書けない)と挙動が割れていた。
    /// 実測(Apple マップの乗換案内): 救済の探し直しの途中でシートが畳まれ、全開のときの矩形の上端 y=131 から地図を4本
    /// ゆっくりドラッグし続けた(約 16s。地図も動かした)。最初の探索・ft_swipe と救済の探し直しが共有する
    static func scrollFrameLocator(for container: ElementInfo, in snapshot: SnapshotResponse) -> FlowLocator? {
        guard let id = container.identifier, !id.isEmpty,
              snapshot.elements.filter({ $0.identifier == id }).count == 1,
              let locator = (try? parseSelectorArgument("#\(id)", argument: "scrollFrame"))?.primary,
              LocatorResolver.match(locator, in: snapshot)?.ref == container.ref else { return nil }
        return locator
    }

    private static func scrollFrameHeight(_ arg: ScrollFrameArg, step: FlowStep,
                                          in snapshot: SnapshotResponse) -> Double? {
        if let original = arg.original {
            guard case .found(let found, _) = RefGuard.relocate(
                original, in: snapshot.elements, screen: snapshot.screen) else { return nil }
            return found.frame.height
        }
        guard let locator = step.scrollFrame else { return nil }
        return ScrollFrameResolution.resolve(locator, in: snapshot)?.frame.height
    }

    /// `StepExecutor` を組むための2つの入力(releasesScrollTouch の反転元 / 空打ちゲート用
    /// uiFramework)。**scrollTo と ft_batch が共有する**(2つ目の判定を作らない) ——
    /// releasesScrollTouch は **iOS だけ true**(Android では 2pt のドラッグがクリックとして
    /// 発火する。StepExecutor の宣言参照)。ここを取り違えると探索直後に行が勝手に選択される。
    /// uiFramework: profile 経由ならドライバ生成時に静的に判定済み(uiFrameworkHints)。
    /// 無ければ attach 中のアプリ(status.sessionBundleID)を AppUIFrameworkQuery に問う(成功だけ記憶)——
    /// 材料は ft_install で入れたパッケージ(installedPackagePaths)→ シミュレータのバンドル → 台帳 →
    /// in-app の自己申告。Android は releasesScrollTouch=false で無関係。
    /// **実機は simctl を撃たない**(udid の形が同じなので `Invalid device` で失敗するだけ。
    /// 実機かどうかは `.fleetest/bridge-<port>.device`)
    func resolveExecutorHints(_ driver: AppDriver, args: [String: Any]) async
        -> (isAndroid: Bool, uiFrameworkHint: AppUIFramework?) {
        let key = Self.sessionKey(args)
        let isAndroid = bridges[key] == "android" || driver is AndroidDriver
        guard !isAndroid else {
            wireAndroidUIFramework(driver, args: args)  // ft_batch の type / clearInput 用
            // DSL と同じく executor にも渡す(nil だと `PaintOrder.isReal` が false = 覆いの判定が走らず、シートの裏の行への tap が
            // 手前の行を押して ok だった)。起動したアプリ、無ければ前面のアプリについて引く
            let bundleID: String?
            if let launched = launchedBundleIDs[key] { bundleID = launched } else { bundleID = (try? await driver.status())?.sessionBundleID }
            return (true, bundleID.flatMap { androidUIFrameworkLookup($0, installedPackagePaths[key]) })
        }
        let status = try? await driver.status()
        guard let bundleID = status?.sessionBundleID else { return (false, nil) }
        if let cached = uiFrameworkHint(key, bundleID: bundleID) { return (false, cached) }
        let physical = connectedPorts[key].flatMap { port in
            (try? RepoRoot.find()).flatMap { BridgeDeviceRecord.load(port: port, repoRoot: $0) }
        } != nil
        let subject = AppUIFrameworkQuery.Subject(platform: "ios", bundleID: bundleID,
                                                  appPath: installedPackagePaths[key],
                                                  udid: udids[key] ?? nil, physical: physical)
        if let framework = await AppUIFrameworkQuery.resolve(subject, bridgeReport: {
            AppUIFrameworkQuery.bridgeReport(status, about: bundleID)
        }).framework {
            uiFrameworkHints[key] = UIFrameworkHint(bundleID: bundleID, framework: framework)
            return (false, framework)
        }
        if physical { uiFrameworkUnknownPending.insert(key) }
        return (false, nil)
    }

    /// **セレクタ解決の唯一の実装**(FTSelector.parse → [primary]+fallbacks →
    /// LocatorResolver.resolvedCandidates)。`matches`(MCPServer+Driver.swift)はこの結果が
    /// 空かどうかを見るだけの薄いラッパー — 2つ目の照合ロジックを作らない。ここは当たった
    /// 要素そのものが要る呼び手(scrollTo の画面外再確認)用
    static func matchedElements(_ selectorText: String, in snapshot: SnapshotResponse) -> [ElementInfo] {
        let parsed = FTSelector.parse(selectorText)
        return ([parsed.primary] + parsed.fallbacks).flatMap {
            LocatorResolver.resolvedCandidates($0, elements: snapshot.elements) ?? []
        }
    }

    /// `ft_scroll_to` 成功文に添える多重ヒットの注記(監査)。**セレクタ依存の本文**
    /// であって木だけから決まる注記ではないので NoteCatalog には登録しない
    /// (NoteCoverageTests のソース走査対象は木由来の注記だけ)
    /// `insideRef` = シートを広げた後に、木の順の先頭(容器の外)ではなく容器の中の一致を採ったときのその ref(それ以外は nil)
    static func multiMatchHint(_ matched: [ElementInfo], insideRef: Int?) -> String {
        guard matched.count >= 2 else { return "" }
        if let insideRef, let first = matched.first, first.ref != insideRef {
            return " (\(matched.count) elements match this selector; [\(insideRef)] inside the scrollFrame list was used,"
                + " not the first in tree order [\(first.ref)])"
        }
        return " (\(matched.count) elements match this selector; the first in tree order was used)"
    }

    /// 「この画面ではシート展開救済が効かない」の記録(`sheetRescueKey` 参照)。
    /// **上限を切る**: セッションが長いほど画面の数だけ指紋が溜まるので、古いものから捨てる
    /// (救済が効かない画面は数個で、10 も覚えれば往復は止まる)
    func rememberFutileSheetRescue(_ snapshot: SnapshotResponse, args: [String: Any]) {
        let key = Self.sessionKey(args)
        var keys = sheetRescueFutile[key] ?? []
        if keys.count >= Self.sheetRescueMemoryCap { keys.removeFirst() }
        keys.insert(Self.sheetRescueKey(snapshot))
        sheetRescueFutile[key] = keys
    }

    static let sheetRescueMemoryCap = 10

    /// 要素が出るまでスクロールして探す。**探索そのものは DSL と同じ StepExecutor に委ねる**。
    ///
    /// 自前でスワイプのループを書かない理由: 整定待ち・キャッシュ回避・容器基準の刻み・
    /// ghost の掴み直し・飛び越しの拾い直し・打ち切りは全部 StepExecutor に入っており、
    /// **同じ知見の2つ目の実装を作ると必ず割れる**(CLAUDE.md「判定は1箇所に置く」)。
    /// ここは FlowStep を1つ組んで投げるだけにする = MCP で届く要素はシナリオでも届く。
    func scrollTo(_ args: [String: Any]) async throws -> [[String: Any]] {
        // **型違いだけ共有の門と同じ文言**にする(stringArgument は使わない —— あちらは
        // selector が ArgumentBounds.mustNotBeEmpty に載っているため空文字を自前の文言より先に
        // 断ってしまう)。必須+空文字の文言は DSL 構文の案内込みで残す
        if let raw = args["selector"], !(raw is String) {
            throw MCPError("selector must be a string (got \(Self.describeArgumentValue(raw)))"
                + " — pass a JSON string, not a number")
        }
        // 空白だけも空として断る(ArgumentBounds.emptyViolation と同じ扱い)
        guard let selectorText = args["selector"] as? String,
              !selectorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPError(Self.scrollToSelectorRequiredMessage)
        }
        guard let direction = FTScrollDirection(rawValue: args["direction"] as? String ?? "down") else {
            throw MCPError("direction must be one of down/up/right/left (content direction)")
        }
        // **構文検査はデバイスに触る前**: `selector: "#"` のような誤りを通すと、見つからないまま
        // 探索が最後まで振り切る(実測46秒)。ここで落とせば driver(args) すら要らない
        let selector = try Self.parseSelectorArgument(selectorText, argument: "selector")
        try Self.validateScrollFrameArg(args)
        let positionalNote = Self.positionalSelectorNote(selector: selector, selectorText: selectorText)
        let scrollDriver = try await driver(args)
        // **曖昧さは「渡す前に見えていた画面」で判定する**: 探索後の木で数えると、リストが
        // 読み込み直しに入っている回に同名の容器が1つしか残らず黙ってしまう
        // (実測。Google マップは探索スワイプのたびに結果を組み直す)
        let beforeScroll = lastSnapshots[Self.sessionKey(args)]
        let scrollFrameArg = try await resolveScrollFrameArg(args, driver: scrollDriver)
        var step = FlowStep(
            action: "scrollTo", locator: selector.primary,
            fallbacks: selector.fallbacks.isEmpty ? nil : selector.fallbacks,
            direction: direction.swipe.rawValue,
            timeout: try Self.doubleArgument(args, "waitSeconds"),
            maxSwipes: try Self.intArgument(args, "maxSwipes") ?? FlowStep.defaultMaxSwipes,
            scrollFrame: scrollFrameArg.locator,
            scrollFrameRect: scrollFrameArg.rect)
        var scrollFrameLabelNote = positionalNote + (scrollFrameArg.note.isEmpty ? "" : "note: the scrollFrame ref was re-checked against the current tree\(scrollFrameArg.note).\n")
        let (isAndroid, uiFrameworkHint) = await resolveExecutorHints(scrollDriver, args: args)
        // **直前の ft_type のキーボードが上がりきってから探索する**(新しい executor は type の印を持たない。
        // 待たないと上がる前の木で「見えている」と判断して送らず、後から上がったキーボードの下に対象が入る =
        // DSL の探索と同じ型。印が無ければ読みを足さない)
        if pendingTypeKeyboardChecks[Self.sessionKey(args)] != nil {
            _ = try await consumePendingTypeKeyboardCheck(try await freshSnapshot(scrollDriver, args: args),
                                                          driver: scrollDriver, args: args)
        }
        // **1回目だけ半開きシートの逆走査を後回しにする**(defersPartialSheetRecovery の宣言参照):
        // sheetCollapsed なら下でシートを展開して再試行し、その再試行が全画面高で同じ救済を
        // 持つので、畳まれた視界での逆走査(実測 7.8s)は丸損になる
        let executor = StepExecutor(driver: scrollDriver,
                                    occlusionOCRMode: .off, releasesScrollTouch: !isAndroid, isAndroid: isAndroid, tunables: executionDefaults(args).tunables,
                                    uiFramework: uiFrameworkHint,
                                    containerInference: executionDefaults(args).containerInference,
                                    defersPartialSheetRecovery: true)
        executor.notesLandscapeWithoutRotate = false
        wireAppGoneGuard(executor, driver: scrollDriver, isAndroid: isAndroid, args: args)
        // **所要時間の内訳の起点**: (a) 1回目の探索 + (b) シート展開救済だけを測る
        // (driver 解決・scrollFrame 解決は上ですでに終わっている)。成功応答だけに載せる
        let timingClock = ContinuousClock()
        let timingStart = timingClock.now
        // 段階の印(`.fleetest/mcp-rpc.log` の phases)。救済が入った回の時間が、最初の探索・シートを広げる・探し直すの
        // どれに使われたかを分ける(16.5 秒の呼び出しの内訳が読めなかった)
        SlowCallWatchdog.mark("scroll search")
        var outcome = await executor.execute(step)
        if let switched = executor.scrollFrameSwitchNote { scrollFrameLabelNote += "note: \(switched).\n" }  // 探索が行の容器へ差し替えた注記(DSL は driverFallback)
        // **必ず撮り直す**(0スワイプで見つかった回も)。executor が解決に使った木を再利用して
        // 1枚ぶん(iOS 実測 2.0s)節約する案は実装して**撤回**した ——
        // 撮り直しは節約ではなく**独立した砦**で、これを省くと「対象が返す木から消えている」
        // (MCPRefGuardTests)と「中心が画面外へ動いた」(MCPScrollToOffscreenGateTests)の
        // 2つのゲートが構造的に無効になる。後者は **0スワイプの witness を持つ**
        // (Apple マップの経路ページャが読み取りの合間に自分で動く)ので、スワイプ数では守れない
        var after: SnapshotResponse
        do {
            after = try await freshSnapshot(scrollDriver, args: args)
        } catch {
            // **探索が失敗していたら、撮れなくても探索の失敗文を返す** —— 撃ったスワイプでアプリが落ちると
            // ランナーは以後の読み取りを 422 で断る。投げ直すと「何回送って見つからなかったか」が 422 の一文に
            // 置き換わる(ft_batch の失敗の分岐と同じ型)。成功していたら撮れない以上確かめようがないので投げる
            guard !StepExecutor.isSuccess(outcome.status) else { throw error }
            let reason = Self.failureReason(outcome)
            // 元のエラーを抱えたまま投げる(MCPError に畳むと、接続断の案内 = 届いたか分からない・記憶の破棄が出ない)
            // 探索の手が投げた case を優先する(届いたか分からないスワイプの配達の注記を、撮れなかった理由で消さない)
            throw MCPAnnotatedError(underlying: outcome.thrownDriverError ?? error, suffix: "",
                                    prefix: scrollFrameLabelNote + "scrollTo \"\(selectorText)\": \(reason)"
                                        + "\n\nCould not take a snapshot after the search: ")
        }
        // **半開きシートは自分で広げて1度だけやり直す**。この形は失敗文で
        // 「グラバーを上へ引け」と案内済みだったが、**案内できるなら自分でできる** ——
        // 実測(Apple マップの経路詳細)では、案内どおり ft_drag してから同じ ft_scroll_to を
        // 撃ち直すだけで通り、2往復を人手で払っていた。
        // 条件は StepExecutor と共有(StepNote.sheetCollapsed)。**グラバーを名前で特定できる
        // ときだけ**動かす —— 当てずっぽうのドラッグは地図やリストを勝手に動かす
        var sheetNote = ""
        var rescueMs: Int?
        var matchOutsideContainer = false
        var preferredInsideRef: Int?
        // **同じ画面で2度は撃たない**(監査): 救済は実測 21.2 秒かかるのに、
        // 1回目が「3回目も同じ」と結論した画面で ft_scroll_to を撃ち直すと全額を再び払っていた。
        // 鍵は木の指紋(sheetRescueKey)—— 画面が変われば指紋も変わるので、記憶は自然に失効する
        let rescueKey = Self.sheetRescueKey(after)
        let rescueKnownFutile = sheetRescueFutile[Self.sessionKey(args)]?.contains(rescueKey) == true
        if StepExecutor.isSuccess(outcome.status) {
            // 成功。救済は要らない
        } else if outcome.notes.contains(.sheetCollapsed), rescueKnownFutile {
            sheetNote = Self.sheetRescueMarker + "skipped — the list stopped moving inside a"
                + " partially open sheet again."
                + " Expanding the sheet was already tried on this exact screen earlier in this"
                + " session and did not help, so it was NOT retried this time (that rescue costs"
                + " seconds)." + Self.sheetManualExpandHint(after) + "\n"
        } else if outcome.notes.contains(.sheetCollapsed),
           let grabber = Self.sheetGrabber(in: after) {
            let rescueStart = timingClock.now
            SlowCallWatchdog.mark("sheet rescue: expanding the sheet")
            let beforeExpansion = after
            let beforeHeight = Self.scrollFrameHeight(scrollFrameArg, step: step,
                                                      in: beforeExpansion)
            let toY = after.screen.height * Self.expandedSheetTopRatio
            try await scrollDriver.drag(fromX: grabber.frame.centerX, fromY: grabber.frame.centerY,
                                        toX: grabber.frame.centerX, toY: toY,
                                        pressSeconds: FlowStep.defaultDragPressSeconds, durationSeconds: 0.5)
            // **rect は展開後の木で作り直す**: シートが伸びると scrollFrameRect の元になった
            // 容器の frame も変わるので、展開前の rect のまま撃つと広がった分を探索できない。
            // 同じ要素を撮り直した木から再照合し、取れなければ従来の rect のまま
            let expanded = try await freshSnapshot(scrollDriver, args: args)
            after = expanded
            if let original = scrollFrameArg.original,
               case .found(let found, _) = RefGuard.relocate(
                   original, in: expanded.elements, screen: expanded.screen) {
                if let locator = Self.scrollFrameLocator(for: found, in: expanded) {
                    step.scrollFrame = locator
                    step.scrollFrameRect = nil
                } else {
                    step.scrollFrameRect = found.frame
                }
            }
            let expandedHeight = Self.scrollFrameHeight(scrollFrameArg, step: step, in: expanded)
            // 伸びなかったら再試行しない(判定は sheetExpansionGrew の宣言参照)
            if !Self.sheetExpansionGrew(beforeHeight: beforeHeight,
                                        expandedHeight: expandedHeight) {
                let beforeHeight = beforeHeight ?? 0
                let expandedHeight = expandedHeight ?? 0
                rescueMs = Int((timingClock.now - rescueStart) / .milliseconds(1))
                // **効かなかったことを覚える**(sheetRescueKey 参照)。鍵は救済**前**の木 ——
                // これが次の呼び出しの1回目の探索が行き着く画面だから
                rememberFutileSheetRescue(beforeExpansion, args: args)
                sheetNote = Self.sheetRescueMarker
                    + "— the list had stopped moving inside a partially open sheet, so"
                    + " [\(grabber.ref)] \(RefGuard.describe(grabber)) was dragged up to expand it,"
                    + " but its height did not increase (\(Int(beforeHeight))pt before,"
                    + " \(Int(expandedHeight))pt after) — the sheet cannot be expanded this way,"
                    + " so the search was not retried."
                    + Self.sheetManualExpandHint(after) + "\n"
            } else if let alreadyThere = Self.visibleAfterExpansion(step: step, in: expanded) {
                // **展開しただけで出ていたら、そこで終わり**(実アプリ監査)。
                // シートを広げる目的は「隠れていた行を出すこと」なので、出た時点で探索の
                // 目的は達成されている。ここで素通しして再スワイプに入ると、**この画面では
                // リスト内のスワイプが外側シートの折りたたみに化ける**ため、せっかく出した行を
                // 自分で引っ込めて「見つからない」で終わる —— 実測(Apple マップの乗換案内・
                // iOS 27 Simulator): 展開後に同じ探索を手で撃つと 0 スワイプ・512ms で成功するのに、
                // 救済の再試行は 16.9〜20.7 秒かけて失敗していた
                rescueMs = Int((timingClock.now - rescueStart) / .milliseconds(1))
                if Self.matchIsOutsideScrollFrame(alreadyThere, step: step, in: expanded) {
                    // **容器の外の一致は「見つかった」と言わない**(再スワイプもしない = 畳むので)。
                    // outcome は失敗のまま下の「届かなかった」の応答へ落とす。シートは既に広げたので手動展開の案内は付けない
                    matchOutsideContainer = true
                    sheetNote = Self.sheetRescueMarker
                        + "— the list had stopped moving inside a partially open sheet, so"
                        + " [\(grabber.ref)] \(RefGuard.describe(grabber)) was dragged up to expand it,"
                        + " and the search was NOT retried (swiping again can collapse the sheet)."
                        + Self.matchOutsideScrollFrameNote(alreadyThere, step: step, in: expanded)
                        + Self.sheetExpansionLayoutNote(before: beforeExpansion, after: after) + "\n"
                } else {
                    // 先頭の一致(容器の外)を飛ばして容器の中を採った回だけ、多重一致の注記でそう言う
                    if let locator = step.locator, LocatorResolver.match(locator, in: expanded)?.ref != alreadyThere.ref {
                        preferredInsideRef = alreadyThere.ref
                    }
                    outcome = StepOutcome(status: .passed, notes: outcome.notes,
                                          resolvedElement: alreadyThere,
                                          scrollSwipes: outcome.scrollSwipes, slowDrags: outcome.slowDrags)
                    sheetNote = Self.sheetRescueMarker
                        + "— the list had stopped moving inside a partially open sheet, so"
                        + " [\(grabber.ref)] \(RefGuard.describe(grabber)) was dragged up to expand it,"
                        + " which revealed the target — the search was NOT retried."
                        + Self.sheetExpansionLayoutNote(before: beforeExpansion, after: after) + "\n"
                }
            } else {
                // **再試行は逆走査つき**(defers... を外した別 executor)。展開後も稀に部分高の
                // ままのことがあり、そこで再び後回しにすると救済がどこにも無くなる
                let retryExecutor = StepExecutor(driver: scrollDriver,
                                                 occlusionOCRMode: .off, releasesScrollTouch: !isAndroid, isAndroid: isAndroid, tunables: executionDefaults(args).tunables,
                                                 uiFramework: uiFrameworkHint,
                                                 containerInference: executionDefaults(args).containerInference)
                retryExecutor.notesLandscapeWithoutRotate = false
                wireAppGoneGuard(retryExecutor, driver: scrollDriver, isAndroid: isAndroid, args: args)
                SlowCallWatchdog.mark("sheet rescue: searching again")
                outcome = await retryExecutor.execute(step)
                after = try await freshSnapshot(scrollDriver, args: args)
                rescueMs = Int((timingClock.now - rescueStart) / .milliseconds(1))
                // **再試行後にシートが元より縮んでいたら名指しする**(実測: Apple
                // マップの乗換案内は、リスト端で続けたスワイプが外側シートの折りたたみに化ける。
                // 黙っていると読み手は同じ探索をもう一度撃つ)
                var shrunkNote = ""
                // **再試行も sheetCollapsed で終わったら、その画面の性質として名指しする**
                // (実測: Apple マップの乗換案内は、リスト内のドラッグが外側シートの
                // 折りたたみに化ける。展開→再試行→また畳まれる、を黙って返すと読み手は
                // 3回目を撃つ)。高さ比較(shrunk)より直接的な証拠なのでこちらを優先する
                if !StepExecutor.isSuccess(outcome.status),
                   outcome.notes.contains(.sheetCollapsed) {
                    rememberFutileSheetRescue(beforeExpansion, args: args)
                    shrunkNote = " The retry ended the same way (the sheet collapsed again) —"
                        + " on this screen drags inside the list collapse the outer sheet instead"
                        + " of scrolling it, so a third attempt will not do better. Read the rows"
                        + " already listed (the ⚠️offscreen ones included), or use the app's own"
                        + " controls to reveal the content."
                        + Self.sheetManualExpandHint(after)
                } else {
                    // **基準は「救済前」or「展開直後」の測れたほう**: 最初の探索のスワイプが
                    // シートを畳んでいると救済前の木に容器が居ない(実測)。展開で容器が
                    // 戻ったなら、その高さとの比較で「再試行がまた畳んだ」を言える。
                    // gone(容器ごと消えた)はここでは言わない —— 展開直後の木はシートの
                    // アニメーション中で計測が不安定(実測)。最終木での判定は下の失敗文が持つ
                    let referenceHeight = beforeHeight ?? expandedHeight
                    let finalHeight = Self.scrollFrameHeight(scrollFrameArg, step: step, in: after)
                    if !StepExecutor.isSuccess(outcome.status),
                       Self.sheetRetryContainerState(beforeHeight: referenceHeight,
                                                     finalHeight: finalHeight) == .shrunk {
                        rememberFutileSheetRescue(beforeExpansion, args: args)
                        shrunkNote = " The scroll container ended up SHORTER than before the rescue"
                            + " (\(Int(referenceHeight ?? 0))pt → \(Int(finalHeight ?? 0))pt) — on"
                            + " this screen a swipe at the list's edge collapses the outer sheet"
                            + " instead of scrolling, so repeating the search will not help; read"
                            + " the visible rows or navigate another way."
                            + Self.sheetManualExpandHint(after)
                    }
                }
                sheetNote = Self.sheetRescueMarker
                    + "— the list had stopped moving inside a partially open sheet, so"
                    + " [\(grabber.ref)] \(RefGuard.describe(grabber)) was dragged up to expand it and"
                    + " the search was retried once."
                    + Self.sheetExpansionLayoutNote(before: beforeExpansion, after: after)
                    + shrunkNote + "\n"
                // **最終木も同じ鍵で覚える**: 次の呼び出しの1回目の探索は、この画面から始まって
                // ここへ戻ってくる。救済前・救済後のどちらの指紋で来ても弾けるようにする
                if !shrunkNote.isEmpty { rememberFutileSheetRescue(after, args: args) }
            }
        }
        // **成功は .passed/.passedViaFallback/.healed の3形**(StepExecutor.isSuccess の定義)。
        // fallback 一致も探索としては成功であり、失敗文を投げると内部 enum(FlowLocator ダンプ)が
        // そのまま利用者に見える(実害)
        guard StepExecutor.isSuccess(outcome.status) else {
            // ここに来る時点で outcome.status は failed/skipped/inconclusive のいずれか
            let reason = Self.scrollFailureReason(Self.failureReason(outcome), sheetRescued: !sheetNote.isEmpty)
            // **失敗の応答にも、成功経路と同じ「木が別のアプリのものだ」を付ける**(アプリが落ちて別のアプリが前面に出た回、
            // 失敗文だけが的外れな対処を言っていた)。同じ判定・同じ文言(switchedAppNote)
            let failedLaunched = launchedBundleIDs[Self.sessionKey(args)]
            let failedSwitched = Self.switchedAppNote(
                launched: failedLaunched, snapshot: after,
                processEvidence: await androidProcessEvidenceForSwitch(
                    launched: failedLaunched, snapshot: after, driver: scrollDriver, args: args),
                stoppedByTool: toolStoppedBundleIDs[Self.sessionKey(args)],
                keyguardShowing: await Self.keyguardFact(for: after, driver: scrollDriver))
            // 届かなくてもスワイプを撃った探索は画面を動かした。下書きに行は残さず(再生しても届かない)、動かした事実だけ TODO に残す
            if let swipes = outcome.scrollSwipes, swipes > 0 {
                var entry = InteractionLog.Entry(
                    step: nil, unresolved: nil, summary: "scrollTo \"\(selectorText)\" (did not reach it)")
                entry.todoNote = Self.failedScrollTodo(selector: selectorText, swipes: swipes)
                recordAction(entry, args: args)
            }
            // **fail-fast(scrollFrame 未解決)は別の文で伝える**: 通常の「did not reach the
            // element」はスワイプを何本か送った前提の文言で、fail-fast は1本も送っていないので
            // そのままでは誤解を招く(StepNote.scrollFrameMissing = DSL と共有した判定)
            if outcome.notes.contains(.scrollFrameMissing) {
                recordSnapshot(after, scrollDriver is AndroidDriver ? "android" : "ios", args)  // 失敗文が列挙する木も台帳へ
                throw MCPError(failedSwitched + scrollFrameLabelNote + "scrollTo \"\(selectorText)\": \(reason)"
                    // fail-fast はスワイプを撃たない = 読み直した木が今の画面(覚えていた木は古いことがある)
                    + Self.scrollAlternativesHint(after))
            }
            // **渡された scrollFrame 容器が最終木から消えていたら名指しする**(実測:
            // Apple マップの乗換案内は探索スワイプがシートごと畳み、最終画面が地図だけになる。
            // 探索開始時には実在した容器(無ければ scrollFrameMissing で上の分岐に入る)なので、
            // 消えたのは探索中 = 同じ探索を繰り返しても届かない)。判定は**最終木**で行う ——
            // 展開直後の木はシートのアニメーション中で計測が不安定(実測)
            var containerGoneNote = ""
            if scrollFrameArg.original != nil || step.scrollFrame != nil,
               Self.scrollFrameHeight(scrollFrameArg, step: step, in: after) == nil {
                containerGoneNote = "note: the scrollFrame container itself is GONE from the final"
                    + " tree — the search swipes collapsed or closed the outer sheet, so repeating"
                    + " the same search will not help. Reopen the sheet (tap the control that"
                    + " showed it) and read the visible rows, or use ft_swipe one screenful at a"
                    + " time instead.\n"
            }
            // **止まった時点で見えているものを一緒に返す**(外部フィードバック)。
            // 「届かなかった」だけだと ft_snapshot の往復が要るうえ、**記法の誤りに気づけない**
            // —— 素のラベルは完全一致なので、「端末情報」は「端末情報を表示」に当たらない。
            // 候補を見せれば、綴り違いなのか記法(`*…*`)不足なのかがその場で分かる
            // **やり直し済みなら先に言う**: 言わないと読み手は失敗文のシート展開ヒントを
            // 読んで**もう一度同じことを手で試す**(そのぶん往復が増える)
            // **内訳は失敗側にも出す**: 実測で 7.8 秒かけて届かなかった回に何も出ず、
            // 何本振ったのかも分からなかった —— 遅さの説明が最も要るのはこちら
            // **シートが原因の失敗には必ず具体手順を添える**(監査)。救済を
            // 撃たなかった/撃てなかった回(グラバーは居るのに `.sheetCollapsed` が立たない、
            // 記憶で省いた等)は、FTCore 側の総称ヒント「drag its grabber upward」で終わっており、
            // 読み手は毎回 ref と目標 y を自分で組み立てていた。**sheetNote が既に出していたら足さない**
            let manualExpand = sheetNote.contains("ft_drag fromRef:") || matchOutsideContainer ? ""
                : ((outcome.notes.contains(.sheetCollapsed) || !sheetNote.isEmpty)
                   ? Self.sheetManualExpandHint(after) : "")
            // **探索中の打ち切りは最終木からは分からない**(ブラウザ監査):
            // 目的の行が画面に入っていた周回で上限に当たっていても、通り過ぎた先の最終画面が
            // 上限内なら `truncationHint(after)` は黙る。実測の2回のうち1回がこれで、
            // 「見つからない」だけを読んだ結果、同じ探索をもう一度撃って 45 秒を捨てた
            let truncatedDuringSearch = outcome.notes.contains(.truncatedDuringSearch)
                && after.truncatedCount == 0
                ? "note: the tree hit the element limit at some point during this search, so the"
                    + " target may have been dropped from the candidates rather than absent —"
                    + " read the screen it should be on with ft_snapshot maxElements:"
                    + " \(BridgeAPI.maxSnapshotElementsCeiling) before concluding it is not there.\n"
                : ""
            // **アプリ内アラートが前面なら、アラートを閉じる案内だけを足す**: 探索はアラートの背面を動かせない(アラートの中の
            // 無名のスクロール領域を scrollFrame 候補に挙げたり、背面のラベルを並べたりしても従えない)
            if let (alert, buttons, refs) = Self.frontInAppAlertWithButtons(after) {
                let alertFailure = failedSwitched + "note: \(RefGuard.describe(alert)) is in front of the app"
                    + Self.inAppAlertButtonsClause(buttons: buttons, refs: refs) + ".\n"
                    + "scrollTo \"\(selectorText)\" did not reach the element (\(reason)) — scrolling cannot move the screen behind"
                    + " the alert, so close it first (ft_tap its button by ref or label — alertButton is only for system alerts)"
                    + " and search again."
                if let cause = outcome.thrownDriverError {
                    throw MCPAnnotatedError(underlying: cause, suffix: "", fullMessage: alertFailure)
                }
                throw MCPError(alertFailure)
            }
            // **展開で行が出たが一致が容器の外だけ = 探索は届いていないが、画面は読める形になった**。失敗として投げると、読み手は「失敗した」と読んでから ft_snapshot を1回足していた(Apple マップの計測で5回中4回)。
            // 届いていないことは文で言い、広げた後の木を返す(エラーにしない)。前置き(別のアプリ・打ち切り)は失敗文と同じものを付ける。下書きの TODO は上で記録済み。**ドライバが投げた回はここに入らない**(届いたか分からない操作の事実は MCPAnnotatedError で運ぶ)・アラートが前面の回は上で投げ済み
            if matchOutsideContainer, outcome.thrownDriverError == nil {
                let (treeArgs, inheritedNote) = inheritingSnapshotFilters(args)
                let cache = SnapshotAnnotationCache()
                markLastGenerationDelivered(args: args)
                recordSnapshot(after, scrollDriver is AndroidDriver ? "android" : "ios", args)
                return text(failedSwitched + scrollFrameLabelNote + sheetNote + containerGoneNote + truncatedDuringSearch
                    + Self.scrollTimingNote(totalMs: Int((timingClock.now - timingStart) / .milliseconds(1)),
                                            swipes: outcome.scrollSwipes, slowDrags: outcome.slowDrags,
                                            rescueMs: rescueMs, timing: outcome.timing)
                    + Self.sheetExpandedWithoutMatchHeadline(selectorText, truncation: Self.truncationHint(after)) + "\n"
                    + inheritedNote
                    + SnapshotRenderer.render(after, flagging: cache.ghostFlags(after),
                                              collapsingBulk: treeArgs["expandBulk"] as? Bool != true,
                                              interactiveOnly: treeArgs["interactiveOnly"] as? Bool == true,
                                              unit: Self.coordinateUnit(scrollDriver)))
            }
            recordSnapshot(after, scrollDriver is AndroidDriver ? "android" : "ios", args)  // 失敗文が列挙する木も台帳へ(漏らすと探した id に dry-run が綴り誤りを疑う)
            let failureMessage: String = (failedSwitched + scrollFrameLabelNote + sheetNote + containerGoneNote
                + truncatedDuringSearch
                + Self.scrollTimingNote(totalMs: Int((timingClock.now - timingStart)
                                                     / .milliseconds(1)),
                                        swipes: outcome.scrollSwipes, slowDrags: outcome.slowDrags,
                                        rescueMs: rescueMs, timing: outcome.timing)
                + "scrollTo \"\(selectorText)\" did not reach the element"
                + " (\(reason))\(manualExpand)\(Self.truncationHint(after))."
                + " \(Self.visibleLabelsHint(after))"
                + (reason.contains("is read as a label") ? "" : Self.scrollNotationHint(selectorText, after: after, beforeScroll: beforeScroll,
                                          backDirection: Self.reversedDirection(direction)))
                + Self.similarLabelsHint(selectorText, in: after)
                + Self.scrollAreaHint(Self.scrollFrameHintTree(args, before: beforeScroll, after: after), args: args, isAndroid: isAndroid))
            // 投げられた DriverError があれば抱えたまま投げる(MCPError に畳むと notDelivered / deliveryUnknown / 接続断の案内が消える)。
            // 文面は組み終えたものをそのまま使う(元の文は reason の「execution error: …」に入っている)
            if let cause = outcome.thrownDriverError {
                throw MCPAnnotatedError(underlying: cause, suffix: "", fullMessage: failureMessage)
            }
            throw MCPError(failureMessage)
        }
        // **成功と言う前に、返す木にそれが居ることを確かめる**(探索で外した)。
        // 探索のスワイプは**ボタンを発火させることがある**(SwiftUI の SUT で実測)。
        // その場合 executor は途中の観測で passed のまま、撮り直した木は**別画面**になり、
        // 「scrolled to #nav_diagnostics」+ `#nav_diagnostics` が居ない木、が返っていた。
        // 決定的再現: E2E-iOS のホームで `#nav_diagnostics`(下部タブの下にある行)
        // **照合は selector で行う**: `scrollTo` は `resolvedElement` を載せない
        // (StepExecutor の scrollTo 経路は要素を掴んでも記録しない)ので、それを当てにすると
        // この検査は一度も走らない。`matches` は waitFor と同じ = DSL と同じ照合
        if !Self.matches(selectorText, in: after) {
            throw MCPError("scrollTo \"\(selectorText)\" reached the element, but it is gone from"
                + " the screen now — the search itself changed the screen"
                + " (a swipe over a tappable row can fire it)\(Self.truncationHint(after))."
                + " \(Self.visibleLabelsHint(after))"
                + " Go back to the screen that has it and retry;"
                + " scrollFrame: <container> keeps the swipes inside the list."
                + Self.scrollAreaHint(after, args: args, isAndroid: isAndroid))
        }
        // **木に居ること ≠ 画面に居ること**: FTCore 側のゲート(runScrollSearch)を通っても、
        // ここは独立した砦として残す。当たった要素が**すべて**中心画面外なら、探索は届いていない
        // (弾切れで振り出しへ戻っただけ)。**executor と同じサイズ免除付きゲートを使う**
        // (TapTargetGeometry.offscreenScrollGateAdvisory) —— 素の offscreenAdvisory のままだと、
        // ビューポートより大きい要素で executor 側は成功しているのにここだけ hard fail する
        // 不整合になる(上の「画面が変わった」エラーとは原因が別なので文も分ける)
        let matchedInTree = Self.matchedElements(selectorText, in: after)
        if !matchedInTree.isEmpty,
           matchedInTree.allSatisfy({
               TapTargetGeometry.offscreenScrollGateAdvisory(for: $0, screen: after.screen) != nil
           }) {
            throw MCPError("scrollTo \"\(selectorText)\" is in the tree but its centre is still off"
                + " screen (⚠️offscreen) — the search ran out of swipes without actually reaching it"
                + "\(Self.truncationHint(after)). \(Self.visibleLabelsHint(after))"
                + " Pass scrollFrame: <container> to keep the swipes inside the right scroll area"
                + " instead of falling back to a whole-screen swipe."
                + Self.scrollAreaHint(Self.scrollFrameHintTree(args, before: beforeScroll, after: after), args: args, isAndroid: isAndroid))
        }
        // fallback 一致は成功だが、利用者が書いた式では見つからなかったことを伝える
        // (primary が空振りする式は将来また空振りしうる)
        var fallbackNote = ""
        if case .passedViaFallback(let locator) = outcome.status {
            fallbackNote = " (matched via the fallback \(locator.summary))"
        }
        // outcome.resolvedElement は StepExecutor が内部で撮った木の native ref を持っている
        // (MCP の ref 世代管理を経由していない)。表示するのは `after`(adoptSnapshot 済み =
        // セッション ref)の番号でなければ tap に使えないので、同一性で引き直す
        var landed = ""
        // 着いた要素を疑わしいときだけプラットフォームに聞く(ft_tap と同じゲート・同じ照会)。
        // 描かれていない(隠れたバー等)と答えられたら見出しを「画面にある」とは言わない
        var landedHidden = false
        var landedUnderKeyboard = false
        // 実際に着いた要素(探索は scrollFrame の部分木の中の一致を採ることがある = 木の順の先頭とは限らない)
        var landedRef: Int?
        if let resolved = outcome.resolvedElement {
            switch RefGuard.relocate(resolved, in: after.elements, screen: after.screen) {
            case .found(let found, _), .ghost(let found):
                landedRef = found.ref
                landed = " → [\(found.ref)] \(RefGuard.describe(found))"
                landedHidden = await !Self.hiddenUnderChromeWarning(
                    found, nativeRef: nativeRef(found.ref, args: args), in: after, driver: scrollDriver).isEmpty
                // 「画面にある」「スクロールした」と言い切る前に1件だけ直接聞く(上のゲートは覆う相手が居ない
                // 「描かれていないだけ」の形で開かない = 隠れたバーのボタンを「already on screen」と言っていた。1件 72〜146ms で探索の所要に比べ小さい)
                if !landedHidden {
                    landedHidden = await Self.isReportedNotHittable(nativeRef: nativeRef(found.ref, args: args), driver: scrollDriver)
                }
                landedUnderKeyboard = KeyboardOcclusion.resolve(
                    reported: after.keyboardFrame, in: after.elements, screen: after.screen).covers(found)
            case .gone:
                landed = ""
            }
        }
        // **多重ヒットは黙らない**(監査): 木順の先頭を掴むのは既定挙動のままだが、
        // 他にも当たりがあったことを言わないと「別の意図しない要素に静かに命中した成功」を
        // 見分けられない(実測: tenki.jp で "*週間*" がタブ「2週間」に当たり、週間予報の行は
        // 無視された)。件数は `matchedInTree` で計算済み = 追加コストは無い
        landed += Self.multiMatchHint(matchedInTree, insideRef: preferredInsideRef ?? landedRef)
        // **木を返す口はすべて名指しする**(掃討で漏れを見つけた)。上の再確認は
        // 「セレクタが居るか」しか見ないので、**別アプリに同じ id がある**と素通しする ——
        // E2E の 4 SUT は id・ラベルが共通契約なので、これは現に起こり得る形
        let scrollToLaunched = launchedBundleIDs[Self.sessionKey(args)]
        let switched = Self.switchedAppNote(
            launched: scrollToLaunched, snapshot: after,
            processEvidence: await androidProcessEvidenceForSwitch(
                launched: scrollToLaunched, snapshot: after, driver: scrollDriver, args: args),
            stoppedByTool: toolStoppedBundleIDs[Self.sessionKey(args)],
            keyguardShowing: await Self.keyguardFact(for: after, driver: scrollDriver))
        // scrollFrame を渡すべき当人なので、複数領域の注記もここに出す(欠陥⑪)
        let scrollAreaNote = args["scrollFrame"] == nil ? (ScrollFrameCandidates.note(after) ?? "")
            : Self.lineNote(Self.scrollAreaHint(Self.scrollFrameHintTree(args, before: beforeScroll, after: after),
                                                args: args, isAndroid: isAndroid))
        // **利用者が渡した式をそのまま残す**(F): 探索はセレクタで書くのが DSL の形なので、
        // ここだけは解決後の要素ではなく渡された式が正しい下書きになる
        var scrollStep = FlowStep(action: "scrollTo", locator: selector.primary)
        scrollStep.direction = direction.swipe.rawValue
        // **セレクタで指せた容器は値ごと残す**(捨てると、通った探索が容器違いで通らない行になる)。
        // 矩形でしか指せなかった(ref で渡して一意なセレクタが無い)ときだけ注記に落とす
        if let locator = step.scrollFrame {
            scrollStep.scrollFrame = locator
        } else if args["scrollFrame"] != nil {
            scrollStep.note = "scrollFrame was used during exploration"
        }
        // 一覧に**スワイプ方向を出さない**: `direction.swipe` は指の動き(下を読むなら up)で、
        // 読み手が指定した意味方向とは逆になる。一覧は「どの手か」を見分けるためのものなので、
        // 逆向きの語を出すと `drop:` の選択を誤らせる
        recordAction(InteractionLog.Entry(
            step: scrollStep, unresolved: nil, summary: "scrollTo \"\(selectorText)\""), args: args)
        // **畳み方は snapshotAfter と同じ規則で継承する**(inheritingSnapshotFilters 参照)
        let (treeArgs, inheritedNote) = inheritingSnapshotFilters(args)
        // **ghostNote と render で畳みの有無を揃える**(ft_snapshot と同じ理由)
        let collapsingBulk = treeArgs["expandBulk"] as? Bool != true
        let totalMs = Int((timingClock.now - timingStart) / .milliseconds(1))
        let timingNote = Self.scrollTimingNote(totalMs: totalMs, swipes: outcome.scrollSwipes,
                                               slowDrags: outcome.slowDrags,
                                               rescueMs: rescueMs, timing: outcome.timing)
        // **ghostNote と render で ghostFlags を共有**: 同じ `after` に対する
        // 応答1回ぶんのキャッシュ。SnapshotAnnotationCache のコメント参照(寿命はこの呼び出しだけ)
        let cache = SnapshotAnnotationCache()
        // **アプリ内のアラートが前面なら、木はアラートの部分木だけ**(snapshotBody と同じ規律 = `AlertTreeScope`)
        markLastGenerationDelivered(args: args)   // ft_scroll_to の木も返した世代(snapshotBody と同じ理由)
        recordSnapshot(after, scrollDriver is AndroidDriver ? "android" : "ios", args)  // 木を返す口は台帳へ(漏らすと探した id に dry-run が綴り誤りを疑う)
        if let inAppAlert = AlertTreeScope.frontInAppAlert(in: after) {
            return text(switched + scrollFrameLabelNote + sheetNote + timingNote
                + Self.scrollToHeadline(selectorText, swipes: outcome.scrollSwipes, hiddenUnderChrome: landedHidden, underKeyboard: landedUnderKeyboard) + "\(landed)\(fallbackNote).\n"
                + Self.inAppAlertNote(inAppAlert, in: after)
                + SnapshotRenderer.render(AlertTreeScope.alertOnly(inAppAlert, in: after), flagging: [:],
                                          collapsingBulk: collapsingBulk, interactiveOnly: false,
                                          unit: Self.coordinateUnit(scrollDriver)))
        }
        return text(switched + scrollFrameLabelNote + sheetNote + timingNote
            + Self.scrollToHeadline(selectorText, swipes: outcome.scrollSwipes, hiddenUnderChrome: landedHidden, underKeyboard: landedUnderKeyboard) + "\(landed)\(fallbackNote)."
            + " The refs below are fresh\n" + inheritedNote + scrollAreaNote
            // **ft_snapshot より少ない**(scrollFrame 候補・重複 id 系は出さない)。その差は
            // NoteCatalog の contexts が持つ = 2箇所の並びを読み比べる必要はない
            + catalogNotes(NoteCatalog.Input(snapshot: after, collapsingBulk: collapsingBulk,
                                             cache: cache, brief: Self.briefKeys(foldsSelectorTables: true),
                                             actionResponse: true, afterScrollSearch: true),
                           context: .scrollTo)
            // **既定で畳む**(expandBulk で戻せる): ft_scroll_to の答えは「探した1つがどこに居るか」
            // なので、地図のピンが数十行並ぶ意味は薄い。ft_snapshot と同じ規則にする
            // (ここだけ interactiveOnly を無視すると常に全行を出してしまう)
            + SnapshotRenderer.render(after, flagging: cache.ghostFlags(after),
                                      collapsingBulk: collapsingBulk,
                                      interactiveOnly: treeArgs["interactiveOnly"] as? Bool == true,
                                      unit: Self.coordinateUnit(scrollDriver)))
    }
}
