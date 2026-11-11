// MCPServer+SelectorTarget.swift
// ft_tap / ft_type / ft_long_press / ft_double_tap / ft_clear_input の `selector`(ref・座標の代わりの指し方)

import Foundation
import FTCore

extension MCPServer {
    /// `selector` を取る単発操作。**ref の経路へ畳むだけ**(門・撮り直し・付け替え・被覆の拒否・記録は ref の経路が全部持つ。
    /// 2つ目の門を書かない)。排他は `exclusiveArgumentGroups`
    static let selectorTargetTools: Set<String> = ["ft_tap", "ft_type", "ft_long_press", "ft_double_tap", "ft_clear_input"]

    /// 撮り直した木で selector を DSL と同じ解決(`LocatorResolver.resolveDetailed`)にかけ、当たった要素と複数一致の注記を返す。
    /// 一致なしは何も撃たずに断る。**複数一致は DSL の tap と同じ要素(ツリー順で `[n]` 番目・既定は先頭)を採る**
    static func resolveSelectorTarget(_ text: String, in snapshot: SnapshotResponse) throws -> (element: ElementInfo, note: String) {
        let parsed = try parseSelectorArgument(text, argument: "selector")
        let step = FlowStep(action: "tap", locator: parsed.primary,
                            fallbacks: parsed.fallbacks.isEmpty ? nil : parsed.fallbacks)
        guard let resolved = LocatorResolver.resolveDetailed(step: step, in: snapshot) else {
            throw MCPError("no element matches \(text) on the current screen — nothing was sent."
                + notationHint(text, in: snapshot) + similarLabelsHint(text, in: snapshot)
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

    /// 呼び手の `args` が selector を持つなら、解決して `ref` を足した引数で `run` を撃つ(`selector` は残す = 下書きが読む)。
    /// 解決は撮り直した木で行う(ref の番号は撮り直しで消えるが selector は消えない、が使う理由)
    func withSelectorTarget(_ args: [String: Any],
                            run: ([String: Any]) async throws -> [[String: Any]]) async throws -> [[String: Any]] {
        guard let selector = args["selector"] as? String else { return try await run(args) }
        let d = try await driver(args)
        let snapshot = try await freshSnapshot(d, args: args)
        let target: (element: ElementInfo, note: String)
        do {
            target = try Self.resolveSelectorTarget(selector, in: snapshot)
        } catch let miss as MCPError {
            // 一致なしは ref の経路(アラートの門)へ届かないので、前面のアラートはここで名指す(読み手は木だけ見て探し続ける)
            throw MCPError(miss.message + (await Self.frontAlertClause(snapshot, driver: d)))
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

    /// 一致なしの断りに添える前面のアラート(アプリ内はボタンの ref つき・無ければシステムのアラートを1問だけ聞く)。無ければ空
    static func frontAlertClause(_ snapshot: SnapshotResponse, driver: AppDriver) async -> String {
        if let (alert, buttons, refs) = frontInAppAlertWithButtons(snapshot) {
            let named = buttons.enumerated().map { index, label in
                refs.count == buttons.count ? "[\(refs[index])] \"\(label)\"" : "\"\(label)\""
            }.joined(separator: " / ")
            return " \(RefGuard.describe(alert)) is in front of the app"
                + (named.isEmpty ? "" : " (buttons: \(named))") + " — handle it first."
        }
        guard let system = await frontSystemAlert(driver: driver) else { return "" }
        return " \(system) — handle it first (ft_tap alertButton:)."
    }

    /// ロケータに当たる**別々の**要素の数(撃った要素を含む)。撃った要素と入れ子(包む・包まれる)の一致は同じ部品
    /// (ボタンとその中の文字が同じラベルを持つ形)なので数えない。複数一致の注記と下書きの耐久性が共有する
    static func separateMatchCount(_ locator: FlowLocator, acted: ElementInfo, in snapshot: SnapshotResponse) -> Int {
        let frame = acted.frame
        let others = (LocatorResolver.candidates(locator, elements: snapshot.elements) ?? [])
            .filter { !TapTargetGeometry.contains(frame, $0.frame) && !TapTargetGeometry.contains($0.frame, frame) }
        return others.count + 1
    }
}
