import Foundation

/// **撃つ前の守りの判定を1箇所に置く**(DSL = `StepExecutor.reachBeforeTouch` と MCP の全道具・ft_batch が呼んで写す)。
/// 守りが tap と ft_type にしか無く、doubleTap・長押し・ドラッグ・ft_batch の ref なし入力が素通りしていた。
/// 文言は呼び手ごとに持つ(MCP は ref を言い、DSL はセレクタを言う)。
public enum PreFireGuard {

    /// キーボードで押し出された・覆われた対象が、キーを押さずに撃てない形
    public enum KeyboardCover {
        /// キーボードの上へせり上がったバー(タブ列・固定バー)が中心を覆っている
        case raisedBar(ElementInfo)
        /// キーボードで枠が細い帯に潰れた(中心を撃っても要素に当たらない)
        case collapsed
    }

    /// キーボードが出ている間だけ。**キーボードの下そのもの**(`KeyboardOcclusion`)は別の判定で、ここは含めない
    public static func keyboardCover(of element: ElementInfo, in snapshot: SnapshotResponse,
                                     keyboard: KeyboardOcclusion) -> KeyboardCover? {
        guard KeyboardWait.isShown(snapshot) else { return nil }
        if let bar = TapTargetGeometry.coveredByBarRaisedAboveKeyboard(
            element, in: snapshot.elements, screen: snapshot.screen, keyboard: keyboard.frame) {
            return .raisedBar(bar)
        }
        return TapTargetGeometry.isCollapsedFrame(element) ? .collapsed : nil
    }

    /// 要素の位置を指で触る操作(撃つ前に `reachBeforeTouch` を通す = キーボードの下・覆いを外してから撃つ)。
    /// 導出元は `StepAction.touchClass`(手書きの集合を持たない)。tap は自前の経路で同じ部品を通る。長押しは tap の `holdSeconds > 0`
    public static let elementTouchActions: Set<String> = Set(
        StepAction.allCases.filter { $0.touchClass == .touchesElement }.map(\.rawValue))

    /// ロケータで対象を引く操作のうち、対象がキーボードの下で木から消えうるもの(= 要素へ撃つ全部)。
    /// 見つからないときにキーボードを閉じて探し直す・失敗文でキーボードの事実を言う対象(`resolveAfterClosingKeyboard`)
    public static let keyboardSensitiveActions: Set<String> = Set(
        StepAction.allCases.filter { $0.touchClass != .noElementTouch }.map(\.rawValue))

    /// ref なし(焦点の欄へ撃つ形)の入力。nil = ref なしの入力ではない
    public enum RefLessInput: String {
        case typing, clearing, pressingEnter
    }

    public static func refLessInput(_ step: FlowStep) -> RefLessInput? {
        guard step.locator == nil else { return nil }
        switch step.action ?? "" {
        case "type": return .typing
        case "clearInput": return .clearing
        case "pressEnter": return .pressingEnter
        default: return nil
        }
    }

    /// 別のアプリが前面のときの ref なし入力の断り文(`frontWarning` = 前面の事実を言う文。空なら断らない = nil)。
    /// 判定(前面が違うか)は呼び手が `ForegroundState.judge` で出す。文言はここ1箇所
    public static func refLessInputRefusal(what: String, frontWarning: String) -> String? {
        guard !frontWarning.isEmpty else { return nil }
        return "refusing \(what) without a ref: it would act on whatever field has focus right now, and nothing was sent."
            + frontWarning + " Bring the app back (ft_launch with resume: true) and pass the field's ref"
    }

    /// 操作の語(断り文の `what`)
    public static func refLessVerb(_ input: RefLessInput) -> String {
        switch input {
        case .typing: return "typing"
        case .clearing: return "clearing"
        case .pressingEnter: return "pressing Enter"
        }
    }
}
