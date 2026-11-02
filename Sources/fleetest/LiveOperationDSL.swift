// ライブ操作で撃った1コマンドを、同じ操作の Swift DSL の1行にする純粋関数(操作記録の右列に出す。
// actionResult の `dsl` 欄 = Sources/fleetest/ApiLiveCommand.swift 冒頭の契約)。
//
// 変換は MCP の下書き(ft_draft_scenario)と同じ道を通す: 撃ったコマンド → `FlowStep` →
// `ScenarioCodeGen.command(for:)`。セレクタの名付けは `SelectorNaming`、但し書きは `DraftNotes`。
// 写像表をここと MCP で別々に持たない(行の形が食い違う)ための置き場。
// 対向: vscode-fleetest/src/liveModel.ts(dsl を表示するだけ。TS 側に変換は持たない)。

import FTCore
import Foundation

enum LiveOperationDSL {

    // MARK: 長押し判定時間

    /// iOS の長押し判定時間[秒]。`UILongPressGestureRecognizer.minimumPressDuration` の既定 0.5 秒
    /// (アプリが変えていればこの値とずれる)。ドラッグの静止がこれ以上なら、OS は押し始めを長押しとして
    /// 扱い得るので `swipePointToPoint`(押してすぐ動く)では同じ操作にならず、`gesture` で書く
    static let iosLongPressSeconds: Double = 0.5
    /// Android の長押し判定時間[秒]。`ViewConfiguration.getLongPressTimeout()` の既定 400ms
    /// (OS の版・端末の「長押しの時間」設定で変わり得る)。使い方は `iosLongPressSeconds` と同じ
    static let androidLongPressSeconds: Double = 0.4

    static func longPressThresholdSeconds(platform: String?) -> Double {
        platform == "android" ? androidLongPressSeconds : iosLongPressSeconds
    }

    // MARK: 行

    /// 撃ったコマンドの DSL の1行(行末コメントつき)。組めない(観測だけ・DSL に対応する行が無い)ときは nil。
    /// - snapshot: 利用者が見ていた直近の観測の木(座標の写し先の解決用。操作の**前**のもの)
    static func line(for command: ApiLiveServeCommand, platform: String?,
                     snapshot: SnapshotResponse?, screen: FTRect?) -> String? {
        rendered(for: command, platform: platform, snapshot: snapshot, screen: screen)?.line
    }

    /// 行と、その行が対象に書いたセレクタ(座標の行・対象を取らない行は nil)。
    /// selector は操作記録の操作の列に添える(actionResult の `dslSelector`。拡張は行から切り出さない)
    static func rendered(for command: ApiLiveServeCommand, platform: String?,
                         snapshot: SnapshotResponse?, screen: FTRect?) -> (line: String, selector: String?)? {
        guard let step = step(for: command, platform: platform, snapshot: snapshot, screen: screen),
              var line = ScenarioCodeGen.command(for: step) else { return nil }
        if let comment = step.note, !comment.isEmpty {
            line += "  // \(comment.replacingOccurrences(of: "\n", with: " "))"
        }
        return (line, step.locator.map { FTSelector.serialize(primary: $0, fallbacks: []) })
    }

    /// 座標の表示は 0.1、秒は 0.001 に丸める(木の枠は 120.30000000000001 のような値で来る)
    private static func point(_ value: Double) -> Double { (value * 10).rounded() / 10 }
    private static func seconds(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

    static func step(for command: ApiLiveServeCommand, platform: String?,
                     snapshot: SnapshotResponse?, screen: FTRect?) -> FlowStep? {
        switch command.cmd {
        case "tap":
            guard let x = command.x, let y = command.y else { return nil }
            return pointStep(action: "tap", x: x, y: y, snapshot: snapshot)
        case "press":
            guard let x = command.x, let y = command.y, let hold = command.duration else { return nil }
            var step = pointStep(action: "tap", x: x, y: y, snapshot: snapshot)
            step.duration = seconds(hold)
            step.maxGestureSeconds = command.maxGestureSeconds
            return step
        case "doubleTap":
            guard let x = command.x, let y = command.y else { return nil }
            return pointStep(action: "doubleTap", x: x, y: y, snapshot: snapshot)
        case "type":
            guard let text = command.text else { return nil }
            return FlowStep(action: "type", text: text)
        case "drag":
            return dragStep(command, platform: platform, screen: screen)
        case "gesture":
            guard let fingers = command.fingers, !fingers.isEmpty, let screen else { return nil }
            var step = FlowStep(action: "gesture")
            step.gesture = TouchGesture.ratioFingers(TouchGesture.fingers(fromPoints: fingers), screen: screen)
            guard !(step.gesture ?? []).isEmpty else { return nil }
            step.maxGestureSeconds = command.maxGestureSeconds
            return step
        case "pinch":
            let scale = command.scale ?? 2.0
            guard scale > 0, scale != 1, scale.isFinite else { return nil }
            var step = FlowStep(action: scale > 1 ? "pinchOut" : "pinchIn")
            step.scale = scale
            let duration = command.duration ?? ApiLiveGestureDefaults.pinchDurationSeconds
            // 既定の所要時間は書かない(DSL の pinchStep と同じ判定)
            step.duration = duration == FlowStep.defaultPinchDurationSeconds ? nil : seconds(duration)
            step.maxGestureSeconds = command.maxGestureSeconds
            return step
        case "home": return FlowStep(action: "home")
        case "appSwitcher": return FlowStep(action: "appSwitcher")
        case "fold":
            guard command.state == "fold" || command.state == "unfold" else { return nil }
            return FlowStep(action: command.state)
        default:
            // refresh = 観測だけ
            return nil
        }
    }

    // MARK: 部品

    /// 座標で撃った tap / press / doubleTap: 点に写る要素に書けるセレクタがあればその行(`PointTarget`)、
    /// 無ければ座標の行(+ 座標の但し書き)
    private static func pointStep(action: String, x: Double, y: Double, snapshot: SnapshotResponse?) -> FlowStep {
        guard let snapshot, let graded = PointTarget.writableSelector(atX: x, y: y, in: snapshot) else {
            return coordinateStep(action: action, x: x, y: y)
        }
        var step = FlowStep(action: action, locator: FTSelector.parse(graded.selector).primary)
        step.note = DraftNotes.joined(DraftNotes.selectorDurability(graded.durability),
                                      graded.pressesThePoint ? nil : DraftNotes.pressedPoint(x: x, y: y))
        return step
    }

    private static func coordinateStep(action: String, x: Double, y: Double) -> FlowStep {
        var step = FlowStep(action: action, x: point(x), y: point(y))
        step.note = DraftNotes.coordinates
        return step
    }

    /// drag: 押してから動かすまでの静止が OS の長押し判定時間に届かなければ `swipePointToPoint`
    /// (座標 + 但し書き)、届いていれば `gesture { FTFinger.hold.move }`(画面に対する比率)
    private static func dragStep(_ command: ApiLiveServeCommand, platform: String?, screen: FTRect?) -> FlowStep? {
        guard let fromX = command.fromX, let fromY = command.fromY,
              let toX = command.toX, let toY = command.toY else { return nil }
        let press = command.press ?? ApiLiveGestureDefaults.dragPressSeconds
        let duration = command.duration ?? ApiLiveGestureDefaults.dragDurationSeconds
        if press < longPressThresholdSeconds(platform: platform) {
            var step = FlowStep(action: "swipePointToPoint",
                                duration: duration == FlowStep.defaultSwipeDurationSeconds ? nil : seconds(duration),
                                maxGestureSeconds: command.maxGestureSeconds,
                                x: point(fromX), y: point(fromY), toX: point(toX), toY: point(toY))
            step.note = DraftNotes.coordinates
            return step
        }
        guard let screen else { return nil }
        let finger = FTFinger(x: fromX, y: fromY)
            .hold(seconds: press)
            .move(x: toX, y: toY, durationSeconds: duration)
        var step = FlowStep(action: "gesture")
        step.gesture = TouchGesture.ratioFingers([finger], screen: screen)
        guard !(step.gesture ?? []).isEmpty else { return nil }
        // 静止 + 移動の合計が既定の上限を超えたら、その秒数を上書きとして書く(書かないと貼った先の DSL が断る。
        // 拡張は静止を 3 秒・移動を 8 秒で切るので合計は 11 秒まで = 上書きの天井には届かない)
        let total = press + duration
        step.maxGestureSeconds = command.maxGestureSeconds
            ?? (total > BridgeAPI.defaultMaxGestureSeconds ? total.rounded(.up) : nil)
        return step
    }
}
