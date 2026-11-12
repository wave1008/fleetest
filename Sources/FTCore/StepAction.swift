import Foundation

/// `StepExecutor` が受ける action の全数と、撃つ前の入口(`reachBeforeTouch`)への分類。
/// action は String なので網羅をコンパイラが見ない。**分類は `default` の無い switch**で、case を足すと分類を決めるまでコンパイルできない。
/// executor の switch に enum に無い action が足されたら `StepActionCoverageTests` が落とす。
public enum StepAction: String, CaseIterable {
    case findImage, findImages, existImage
    case swipe, scroll, scrollToEdge, flick, scrollTo, swipePointToPoint
    case fold, unfold, hinge, rotateTo
    case pressEnter, hideKeyboard, holdEnd, waitForSettle, select, setPickerValue, setSliderValue
    case tap, type, clearInput
    case doubleTap, holdStart, swipeElementToElement, swipeBy, pinchOut, pinchIn, gesture

    public enum TouchClass {
        /// 要素の位置を指で触る・押す。撃つ前に `reachBeforeTouch` を通す(tap の長押しもここ)
        case touchesElement
        /// 要素へ撃つが、自前の経路(lift → 閉じる → 撃つ)で同じ部品を通る(押すだけの tap・type・clearInput)
        case ownGuardedPath
        /// 要素の位置を指で触らない(座標・画面全体・読むだけ・アプリや OS への操作)
        case noElementTouch
    }

    public var touchClass: TouchClass {
        switch self {
        case .doubleTap, .holdStart, .swipeElementToElement, .swipeBy, .pinchOut, .pinchIn, .gesture:
            return .touchesElement
        case .tap, .type, .clearInput:
            return .ownGuardedPath
        case .findImage, .findImages, .existImage, .swipe, .scroll, .scrollToEdge, .flick, .scrollTo,
             .swipePointToPoint, .fold, .unfold, .hinge, .rotateTo, .pressEnter, .hideKeyboard, .holdEnd,
             .waitForSettle, .select, .setPickerValue, .setSliderValue:
            return .noElementTouch
        }
    }

    /// 座標ドラッグで指を動かす操作(本物のタッチ = 終わった後に慣性が残りうる)。`swipeWithFallback` を通る
    /// swipe / scroll 系は経路の中で慣性を立てるので含めない。**ここが true の操作は `executeActionRetryingUndelivered` が
    /// 成功の後に `swipeInertiaPending` を立てる**(次の触る操作が空打ちで吸う)。default の無い switch = case を足すと分類が要る
    public var dragsByCoordinates: Bool {
        switch self {
        case .flick, .swipePointToPoint, .swipeElementToElement, .swipeBy:
            return true
        case .findImage, .findImages, .existImage, .swipe, .scroll, .scrollToEdge, .scrollTo, .fold, .unfold,
             .hinge, .rotateTo, .pressEnter, .hideKeyboard, .holdEnd, .waitForSettle, .select, .setPickerValue, .setSliderValue, .tap, .type,
             .clearInput, .doubleTap, .holdStart, .pinchOut, .pinchIn, .gesture:
            return false
        }
    }

    /// 成功の後に画面が変わりうる操作(= 次のロケータ操作の解決は、キャッシュを迂回した新しい木で読む)。
    /// `executeActionRetryingUndelivered` が `nextResolveBypassesCache` を立てる唯一の分類。
    /// 掴む・待つ・画像の判定は画面に触れない。default の無い switch = case を足すと分類が要る
    public var mayChangeScreen: Bool {
        switch self {
        case .findImage, .findImages, .existImage, .waitForSettle, .select:
            return false
        case .swipe, .scroll, .scrollToEdge, .flick, .scrollTo, .swipePointToPoint, .fold, .unfold, .hinge, .rotateTo,
             .pressEnter, .hideKeyboard, .holdEnd, .setPickerValue, .setSliderValue, .tap, .type, .clearInput, .doubleTap, .holdStart,
             .swipeElementToElement, .swipeBy, .pinchOut, .pinchIn, .gesture:
            return true
        }
    }

    /// 注記の語(「the tap will land on the keyboard」の tap の所)
    public var touchNoun: String {
        switch self {
        case .pinchOut, .pinchIn: return "pinch"
        case .swipeBy, .swipeElementToElement: return "drag"
        case .gesture: return "gesture"
        case .doubleTap: return "double tap"
        case .holdStart: return "hold"
        case .tap, .type, .clearInput, .findImage, .findImages, .existImage, .swipe, .scroll, .scrollToEdge,
             .flick, .scrollTo, .swipePointToPoint, .fold, .unfold, .hinge, .rotateTo, .pressEnter,
             .hideKeyboard, .holdEnd, .waitForSettle, .select, .setPickerValue, .setSliderValue:
            return "tap"
        }
    }

    public static func touchNoun(for action: String) -> String { StepAction(rawValue: action)?.touchNoun ?? "tap" }
}
