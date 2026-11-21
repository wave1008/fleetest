// MCPServer+SelectorTarget.swift
// ft_tap / ft_type / ft_long_press / ft_double_tap / ft_clear_input の `selector`(ref・座標の代わりの指し方)

import Foundation
import FTAndroid
import FTCore

extension MCPServer {
    /// `selector` を取る単発操作。**ref の経路へ畳むだけ**(門・撮り直し・付け替え・被覆の拒否・記録は ref の経路が全部持つ。
    /// 2つ目の門を書かない)。排他は `exclusiveArgumentGroups`
    static let selectorTargetTools: Set<String> = ["ft_tap", "ft_type", "ft_long_press", "ft_double_tap", "ft_clear_input", "ft_set_picker_value", "ft_set_slider_value"]

    /// 撮り直した木で selector を DSL と同じ解決(`LocatorResolver.resolveDetailed`)にかけ、当たった要素と複数一致の注記を返す。
    /// 一致なしは何も撃たずに断る。**複数一致は DSL の tap と同じ要素(ツリー順で `[n]` 番目・既定は先頭)を採る**
    static func resolveSelectorTarget(_ text: String, in snapshot: SnapshotResponse, isAndroid: Bool) throws -> (element: ElementInfo, note: String) {
        let parsed = try parseSelectorArgument(text, argument: "selector")
        guard let resolved = LocatorResolver.resolveDetailed(step: selectorStep(parsed), in: snapshot) else {
            throw MCPError("no element matches \(text) on the current screen — nothing was sent."
                + notationHint(text, in: snapshot) + similarLabelsHint(text, in: snapshot)
                + childlessScopeHint(parsed.primary, in: snapshot, isAndroid: isAndroid)
                + hiddenOrOffscreenHint(in: snapshot, isAndroid: isAndroid)
                + " Take an ft_snapshot to read the current labels/ids.")
        }
        // 序数 `[n]` と相対セレクタは「複数のうちの1つ」を自分で選んだ書き方なので数えない
        let used = resolved.usedFallback ?? parsed.primary
        guard used.index == nil, used.relative?.isEmpty ?? true else { return (resolved.element, "") }
        let total = separateMatchCount(used, acted: resolved.element, in: snapshot)
        guard total > 1 else { return (resolved.element, "") }
        return (resolved.element, "note: selector \(text) matched \(total) separate elements; acted on [\(resolved.element.ref)]"
            + " — the same one a scenario line would pick. To name one, write its #id, a longer label, or a"
            + " scoped/indexed form (ft_snapshot's \"write one of these instead\" notes list writable ones).\n")
    }

    /// 一致なしの断りに添える「木に無い理由の候補」。キーボードが出ていれば、窓が縮んで下の要素が木から消えている
    /// (Android と、iOS の Compose Multiplatform = 窓をキーボードの上へ詰める。iOS の他の作りは覆われても木に残るので「消えうる」と言う)。
    /// MCP の ft_tap / ft_type はキーボードを閉じない(シナリオの tap / type は閉じる)ので、閉じる手を先に言う。判定は共有の `KeyboardWait.isShown`
    static func hiddenOrOffscreenHint(in snapshot: SnapshotResponse, isAndroid: Bool) -> String {
        if KeyboardWait.isShown(snapshot) {
            if isAndroid {
                return " The soft keyboard is up — on Android, what sits below it leaves the tree: close it with"
                    + " ft_hide_keyboard and look again."
            }
            return " The soft keyboard is up — an app that shrinks its window above it (Compose Multiplatform) drops what"
                + " sat below it from the tree: close it with ft_hide_keyboard and look again."
        }
        return " If it is outside the visible part of a list, ft_scroll_to it first, then act on it."
    }

    /// 呼び手の `args` が selector を持つなら、解決して `ref` を足した引数で `run` を撃つ(`selector` は残す = 下書きが読む)。
    /// 解決は撮り直した木で行う(ref の番号は撮り直しで消えるが selector は消えない、が使う理由)
    func withSelectorTarget(_ args: [String: Any],
                            run: ([String: Any]) async throws -> [[String: Any]]) async throws -> [[String: Any]] {
        guard let selector = args["selector"] as? String else { return try await run(args) }
        let d = try await driver(args)
        let isAndroid = bridges[Self.sessionKey(args)] == "android" || d is AndroidDriver
        var snapshot = try await freshSnapshot(d, args: args)
        let target: (element: ElementInfo, note: String)
        // 一致なしは何も撃っていないので、シナリオの行と同じ回数・間隔(`StepExecutor.defaultLocatorRetryAttempts` と
        // `PollBackoff`。合計約 0.7 秒)だけ撮り直して探す(遷移の直後の1回で断ると、直後に現れる要素で外れた = Apple マップの実測)
        var backoff = PollBackoff()
        var attempt = 0
        while true {
            do {
                target = try Self.resolveSelectorTarget(selector, in: snapshot, isAndroid: isAndroid)
                break
            } catch let miss as MCPError {
                let parses = (try? Self.parseSelectorArgument(selector, argument: "selector")) != nil
                guard attempt < StepExecutor.defaultLocatorRetryAttempts, parses else {
                    // 文法の誤りはアラートを閉じても直らないので、アラートを名指さない(問い合わせも撃たない)
                    guard parses else { throw miss }
                    // 一致なしは ref の経路(アラートの門)へ届かないので、前面のアラートはここで名指す(読み手は木だけ見て探し続ける)
                    throw MCPError(Self.selectorMissMessage(miss.message,
                                                            alertClause: await Self.frontAlertClause(snapshot, driver: d)))
                }
                attempt += 1
                try await Task.sleep(for: backoff.nextDelay())
                snapshot = try await freshSnapshot(d, args: args)
            }
        }
        var resolved = args
        resolved["ref"] = target.element.ref
        sessions[Self.sessionKey(args), default: DeviceSession()].selectorJustRead = snapshot
        defer { sessions[Self.sessionKey(args), default: DeviceSession()].selectorJustRead = nil }
        var out = try await run(resolved)
        guard !target.note.isEmpty, !out.isEmpty, let first = out[0]["text"] as? String else { return out }
        out[0]["text"] = target.note + first
        return out
    }

    /// スコープの容器は見つかったが木の上で中身を持たない(判定は `LocatorResolver.childlessScopeContainer` を DSL と共有・文言はここ)
    static func childlessScopeHint(_ locator: FlowLocator, in snapshot: SnapshotResponse, isAndroid: Bool) -> String {
        guard let container = LocatorResolver.childlessScopeContainer(of: locator, in: snapshot.elements) else { return "" }
        // 理由は DSL と同じ選び方(葉の型なら中身を持たない型・iOS の入れ物の型だけ CMP の平坦化)
        let reason: String
        if !LocatorResolver.childlessContainerIsGroup(container) {
            reason = " (it is a \(container.type), which holds no other elements)"
        } else if !isAndroid {
            reason = " (on iOS, Compose Multiplatform lists the contents of a Row/Column that only has a testTag beside it)"
        } else {
            reason = ""
        }
        return " The scope's container \(RefGuard.describe(container)) has nothing under it in the tree\(reason), so a `>>` scope"
            + " on it never matches — drop the scope and use a unique #id, a label, or a relative selector (#neighbour:right)."
    }

    /// 一致なしの断り。**前面のアラートがあるならそれを先頭に置く**(末尾に置くと主文の「no element matches」だけ読まれ、
    /// 「要素が無い」と誤読された = Apple マップの計測で、アラートの陰の #TransitButton)
    static func selectorMissMessage(_ miss: String, alertClause: String) -> String {
        alertClause.isEmpty ? miss : "refusing: " + alertClause + " Behind it, " + miss
    }

    /// 一致なしの断りに添える前面のアラート(アプリ内はボタンの ref つき・無ければシステムのアラートを1問だけ聞く)。無ければ空
    static func frontAlertClause(_ snapshot: SnapshotResponse, driver: AppDriver) async -> String {
        if let (alert, buttons, refs) = frontInAppAlertWithButtons(snapshot) {
            return "\(RefGuard.describe(alert)) is in front of the app"
                + inAppAlertButtonsClause(buttons: buttons, refs: refs) + " — handle it first."
        }
        guard let system = await frontSystemAlert(driver: driver) else { return "" }
        return "\(system) — handle it first (ft_tap alertButton:)."
    }

    /// アプリ内アラートのボタンの列挙(ref つき = そのまま ft_tap に渡せる)。ボタンが無ければ空。
    /// 一致なしの断り・ft_scroll_to の断り・alertButton の断りが共有する
    static func inAppAlertButtonsClause(buttons: [String], refs: [Int]) -> String {
        guard !buttons.isEmpty else { return "" }
        let named = buttons.enumerated().map { index, label in
            refs.count == buttons.count ? "[\(refs[index])] \"\(label)\"" : "\"\(label)\""
        }.joined(separator: " / ")
        return " (buttons: \(named))"
    }

    /// ロケータに当たる**別々の**要素の数(撃った要素を含む)。撃った要素と入れ子(包む・包まれる)の一致は同じ部品
    /// (ボタンとその中の文字が同じラベルを持つ形)なので数えない。複数一致の注記と下書きの耐久性が共有する
    static func separateMatchCount(_ locator: FlowLocator, acted: ElementInfo, in snapshot: SnapshotResponse) -> Int {
        let frame = acted.frame
        let others = (LocatorResolver.candidates(locator, elements: snapshot.elements) ?? [])
            .filter { !TapTargetGeometry.contains(frame, $0.frame) && !TapTargetGeometry.contains($0.frame, frame) }
        return others.count + 1
    }

    static func selectorStep(_ parsed: FTSelector) -> FlowStep {
        FlowStep(action: "tap", locator: parsed.primary, fallbacks: parsed.fallbacks.isEmpty ? nil : parsed.fallbacks)
    }

    /// 呼び手が渡した selector の耐久性(下書き用)。**撃つときと同じ解決で、実際に当たった書き方**(`a||b` の後ろ側を含む)を見る:
    /// 相対 = 相対・序数か別々の複数に当たった = 位置依存・それ以外 = 安定。解決できなければ nil(呼び手の推奨の格付けのまま)
    static func givenSelectorDurability(_ text: String, acted: ElementInfo, in snapshot: SnapshotResponse) -> Durability? {
        guard let parsed = try? parseSelectorArgument(text, argument: "selector") else { return nil }
        let used = LocatorResolver.resolveDetailed(step: selectorStep(parsed), in: snapshot)?.usedFallback ?? parsed.primary
        if used.relative?.isEmpty == false { return .relative }
        return used.index != nil || separateMatchCount(used, acted: acted, in: snapshot) > 1 ? .indexed : .stable
    }
}
