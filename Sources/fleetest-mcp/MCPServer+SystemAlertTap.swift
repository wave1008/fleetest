// ft_tap alertButton: — 前面のシステムアラート(SpringBoard)のボタンを、アプリへのセッションを保ったまま押す。
// 以前は ft_launch(springboard)→ ft_tap(ref)→ ft_launch(resume)の3回が要った。

import Foundation
import FTCore

extension MCPServer {

    /// **押すのはエージェントが名指ししたボタンだけ**(自動では押さない。ツールが自分で閉じる範囲 =
    /// 何も決めないボタンと権限の拒否側は広げない)。MCP の iOS は常に XCUITest なので SpringBoard を掴める。
    /// 順序: 照会(`/systemalert`)でボタンの実在を確かめる →
    /// SpringBoard へ向ける(ft_launch の springboard と同じ非破壊の経路)→ 同じラベルの button を押す →
    /// **元のアプリへ attach で向け直す**(activate は使わない = 前面確認だけ。CLAUDE.md の attach の規律)
    /// alertButton を撃ったがシステムのアラートが無いときの断り。アプリ内のアラートが前面なら ft_tap で押すよう名指す
    static func noSystemAlertRefusal(inApp: (alert: ElementInfo, buttons: [String], buttonRefs: [Int])?) -> String {
        guard let inApp else { return "alertButton: no system alert is in front of the app — nothing was tapped" }
        return "alertButton: no system alert is in front of the app — nothing was tapped. The alert in front is the app's own:"
            + " \(RefGuard.describe(inApp.alert))" + inAppAlertButtonsClause(buttons: inApp.buttons, refs: inApp.buttonRefs)
            + " — press its button with ft_tap (ref or selector), not alertButton"
    }

    func tapSystemAlertButton(_ label: String, driver d: AppDriver,
                              args: [String: Any]) async throws -> [[String: Any]] {
        let pressed = try await pressSystemAlertButton(label, driver: d, args: args)
        return text(pressed + waitForWithoutSnapshotAfterNote(args) + (await snapshotAfterBody(args, outsideTheAppTree: true)))
    }

    /// `alertButton` を本来の操作(selector / ref / text 等)と一緒に渡された呼び出しの前段: ボタンを押してアプリへ向け直し、
    /// その1文を返す(呼び手が操作の結果の前に付ける)。押せなければ投げる = 本来の操作も撃たない。
    /// 実測(Apple マップの計測): 許可のアラートが操作のたびに後から出て、断られる → 押す → 撃ち直す で1周あたり4〜6回の呼び出しを使っていた
    func pressingSystemAlertFirst(_ args: [String: Any], driver d: AppDriver) async throws -> String {
        guard let button = try Self.stringArgument(args, "alertButton") else { return "" }
        return try await pressSystemAlertButton(button, driver: d, args: args) + " Then: "
    }

    /// `alertButton` と本来の操作を1回の呼び出しで: 先にボタンを押し(押せなければ何も撃たずに投げる)、
    /// `alertButton` を外した引数で本来の操作を撃つ。応答の先頭に押した1文を付ける。操作が失敗したら、押したことを添えて投げる
    /// (アラートはもう閉じている = 撃ち直すなら alertButton を外す)
    func withSystemAlertPressedFirst(_ args: [String: Any],
                                     _ body: ([String: Any]) async throws -> [[String: Any]]) async throws -> [[String: Any]] {
        guard args["alertButton"] != nil else { return try await body(args) }
        let prefix = try await pressingSystemAlertFirst(args, driver: try await driver(args))
        var rest = args
        rest.removeValue(forKey: "alertButton")
        var content: [[String: Any]]
        do {
            content = try await body(rest)
        } catch {
            throw MCPError(prefix + error.localizedDescription
                + " (the alert is already closed — retry without alertButton)")
        }
        if let i = content.firstIndex(where: { $0["type"] as? String == "text" }), let first = content[i]["text"] as? String {
            content[i]["text"] = prefix + first
        } else {
            content.insert(["type": "text", "text": prefix], at: 0)
        }
        return content
    }

    /// 前面のシステムアラートのボタンを押し、セッションをアプリへ戻す。戻り値は「押した・どこへ戻ったか」の1文
    func pressSystemAlertButton(_ label: String, driver d: AppDriver, args: [String: Any]) async throws -> String {
        let key = Self.sessionKey(args)
        let probe: SystemAlertProbeResponse?
        switch await d.systemAlert() {
        case .value(let answer): probe = answer
        case .notAnswerable:
            throw MCPError("alertButton: this driver cannot check for a system alert (on Android a system dialog is in the"
                + " element list — tap its button by ref) — nothing was tapped")
        case .failed(let reason):
            throw MCPError("alertButton: could not check for a system alert"
                + " (\(reason)) — nothing was tapped")
        }
        guard let alert = probe, alert.present else {
            // **前面がアプリ内のアラートなら、それとボタンの ref を名指す**(計測: アプリ内アラートへ alertButton を撃ち、
            // この断りだけでは何で押すのか分からなかった)。撮り直すのは断る経路だけ
            let inApp = (try? await freshSnapshot(d, args: args)).flatMap { Self.frontInAppAlertWithButtons($0) }
            // 名指した ref を返した世代として印す(印さないと後の撮影で世代ごと捨てられ、案内した ref が失効する)
            if inApp != nil { markLastGenerationDelivered(args: args) }
            throw MCPError(Self.noSystemAlertRefusal(inApp: inApp))
        }
        let title = alert.title.map { "\"\($0)\"" } ?? "(untitled)"
        guard alert.buttons.contains(where: { Self.alertButtonMatches($0, label) }) else {
            throw MCPError("alertButton: the system alert \(title) has no button \"\(label)\" — its"
                + " buttons are \(alert.buttons.map { "\"\($0)\"" }.joined(separator: " / ")). Nothing was tapped")
        }
        let returnTo = launchedBundleIDs[key].flatMap { $0 == Self.springboardBundleID ? nil : $0 }
            ?? lastSnapshots[key]?.sessionBundleID.flatMap { $0 == Self.springboardBundleID ? nil : $0 }
        // **SpringBoard へ向けた後の失敗(木が読めない・ref が古い・横向きで 422)でも元のアプリへ向け直して抜ける**
        // (向けたまま抜けると、以後の ft_snapshot は「ホーム画面の木」・ft_status は springboard と言い続ける)
        func reattachOnFailure() async { if let app = returnTo { try? await d.attach(bundleID: app) } }
        try await d.launch(bundleID: Self.springboardBundleID)
        let board: SnapshotResponse
        do { board = try await d.snapshot() } catch { await reattachOnFailure(); throw error }
        // **アラートの中の button だけ**を見る(ホーム画面にも同じ文字のアイコンがありうる)
        let inAlert = Self.systemAlertButtons(in: board)
        guard let button = inAlert.first(where: { Self.alertButtonMatches($0.label, label) }) else {
            await reattachOnFailure()
            throw MCPError("alertButton: the alert \(title) listed \"\(label)\" but SpringBoard's tree has"
                + " no such button inside an alert (it may have just closed) — nothing was tapped")
        }
        do { try await d.tap(ref: button.ref) } catch { await reattachOnFailure(); throw error }
        recordAction(InteractionLog.Entry(
            step: nil,
            unresolved: "pressed \"\(label)\" on the system alert \(title) — in a scenario, declare it with"
                + " iosAlertHandler instead",
            summary: "tap system alert button \"\(label)\""), args: args)
        var back = " The session is still pointed at SpringBoard (the app to return to is not known) —"
            + " ft_launch your app with resume: true to go back to it with its state kept."
        if let app = returnTo {
            do {
                try await d.attach(bundleID: app)
                back = " The session is back on \(app)."
            } catch {
                // **向け直せないことを伝えて止める**(activate へ倒さない: 前面でないアプリを前面化すると
                // 画面を動かす。押した結果、別のアラートや別のアプリが前に出ていることがある)
                back = " Could not re-attach to \(app) (\(error.localizedDescription)) — something other"
                    + " than the app may be in front (another alert?). Check with ft_snapshot."
            }
        }
        return "Pressed \"\(label)\" on the system alert \(title).\(back)"
    }

    static let springboardBundleID = "com.apple.springboard"

    /// システムアラートの扱い方の案内(断り・注記が共有する)。**SpringBoard を開いて ref で押す3手を案内しない** ——
    /// 計測で ft_type の失敗がその古い手順を返し、ft_tap の断り(alertButton)と食い違った
    static let pressSystemAlertAdvice = "press its button with `ft_tap alertButton: \"<button>\"` (it returns to your"
        + " app; pass alertButton together with your next action's target to do both in one call)"

    /// SpringBoard の木のうち、alert の部分木にある button(preorder + depth で alert の子孫を取る)
    static func systemAlertButtons(in board: SnapshotResponse) -> [ElementInfo] {
        var result: [ElementInfo] = []
        var alertDepth: Int?
        for element in board.elements {
            if let depth = alertDepth, element.depth <= depth { alertDepth = nil }
            if ElementInfo.normalizedType(element.type) == "alert" {
                alertDepth = element.depth
                continue
            }
            if alertDepth != nil, ElementInfo.normalizedType(element.type) == "button" {
                result.append(element)
            }
        }
        return result
    }
}

extension MCPServer {
    /// `iosAlertHandler(button:)` の完全一致の分岐と同じ照合(`FlowMatchMode.exact` + 画面の文字の正規化)
    static func alertButtonMatches(_ buttonLabel: String?, _ wanted: String) -> Bool {
        FlowMatchMode.exact.matches(buttonLabel, wanted, normalization: .text)
    }
}
