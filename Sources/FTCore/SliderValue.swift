// スライダーを値で合わせる(DSL setSliderValue / MCP ft_set_slider_value)。照合と止め方の判定はここ1か所。
// 値は「木の value に出る数」(valueIs が読むもの)で比べる: "75%"(UIKit / SwiftUI / RN の iOS)・"75.0"(Compose の iOS)・
// "75"(Android の RangeInfo)・Flutter の Android はラベルの "75%"。単位(%)は落として数で比べる。
// 止める条件は観測できる事象だけ(回数の定数を置かない): 一致した / 送れなかった・値が読めなかった / 動かなかった(端) /
// 目当てをまたいだ(刻みが合わない)/ 位置の探索で新しい値が出なくなった。1回撃つごとに読む(届いたか分からない送りを重ねない)。

import Foundation

public enum SliderValueMatch {

    /// 値の文字の中の最初の数(`"75%"` → 75・`"50.0"` → 50・`"-3.5 dB"` → -3.5)。数が無ければ nil
    public static func number(_ text: String) -> Double? {
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            let startsNumber = c.properties.numericType != nil && c.isASCII
                || (c == "-" && i + 1 < scalars.count && scalars[i + 1].isASCII
                    && scalars[i + 1].properties.numericType != nil)
            guard startsNumber else { i += 1; continue }
            var token = String(c)
            var j = i + 1
            var seenDot = false
            while j < scalars.count {
                let d = scalars[j]
                if d.isASCII, d.properties.numericType != nil { token.unicodeScalars.append(d) }
                else if d == ".", !seenDot, j + 1 < scalars.count, scalars[j + 1].isASCII,
                        scalars[j + 1].properties.numericType != nil {
                    seenDot = true
                    token.unicodeScalars.append(d)
                } else { break }
                j += 1
            }
            return Double(token)
        }
        return nil
    }

    /// 値の数が `wanted` と等しいか。**丸めない**(表示の桁で一致を作ると、刻みの無いスライダーで別の値に止まって緑になる)。
    /// 比べるのは表示の文字を数にしたもの同士なので、浮動小数の誤差だけ吸う(`1e-9` × 大きさ = 文字にした値の往復の誤差)
    public static func matches(current: String, wanted: Double) -> Bool {
        guard let value = number(current) else { return false }
        return abs(value - wanted) <= 1e-9 * max(1, abs(wanted))
    }
}

/// 合わせた後に読めた値と、撃った回数
public struct SliderValueOutcome: Sendable, Equatable {
    public var value: String
    public var steps: Int
    public init(value: String, steps: Int) {
        self.value = value
        self.steps = steps
    }
}

/// 1回撃った結果。`performed` = 撃つ操作が受理された・`value` = 撃った後に読み直した値(nil = 読めなかった)・
/// `actions` = 撃てなかったときにブリッジが言った、そのノードの持つ操作(Android。失敗文に事実として出す)
public struct SliderStepResult: Sendable, Equatable {
    public var performed: Bool
    public var value: String?
    public var actions: [String]?
    public init(performed: Bool, value: String?, actions: [String]? = nil) {
        self.performed = performed
        self.value = value
        self.actions = actions
    }
}

public enum SliderValueLoop {

    public enum Step: String, Sendable, Equatable {
        /// 値を増やす向き(iOS の accessibilityIncrement・Android の ACTION_SCROLL_FORWARD)
        case increment, decrement
    }

    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case stopped(lastValue: String?, wanted: Double, reason: String)
        /// **今の値が読めていて、目当ての向きへの1段目で値が動かなかった**。この送り方では動かせない(iOS の in-app で SwiftUI の
        /// 刻み付きスライダーが accessibilityIncrement で動かなかった = 実測)か、その向きの端。呼び手は別の経路へ回してよい
        /// (iOS は XCUITest ブリッジの位置で合わせる経路。端なら向こうが範囲の外と言う)
        case firstStepDidNotMove(lastValue: String, wanted: Double, direction: Step)
        /// ブリッジが1段目を撃てなかった(そのノードが送る操作を持たない)。`actions` = ブリッジが言ったノードの持つ操作
        case notPerformed(lastValue: String?, wanted: Double, direction: Step, actions: [String]?)

        public var description: String {
            switch self {
            case let .stopped(last, wanted, reason):
                return "the slider stopped at \(last.map { "'\($0)'" } ?? "an unreadable value"),"
                    + " not \(SliderValueLoop.format(wanted)): \(reason)"
            case let .notPerformed(last, wanted, direction, actions):
                let taken = actions.map { " (the slider takes only: \($0.isEmpty ? "no actions" : $0.joined(separator: ", ")))" } ?? ""
                return "the slider stopped at \(last.map { "'\($0)'" } ?? "an unreadable value"),"
                    + " not \(SliderValueLoop.format(wanted)): the bridge could not \(direction.rawValue) the slider" + taken
            case let .firstStepDidNotMove(last, wanted, direction):
                return "the slider stopped at '\(last)', not \(SliderValueLoop.format(wanted)): one \(direction.rawValue)"
                    + " did not change the value (the end of the slider, or it does not take that action)"
            }
        }
    }

    public static func format(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    /// **1段ずつ送って合わせる**(in-app の accessibilityIncrement/Decrement・Android の送り)。向きは今の値と目当ての大小で決める。
    /// 今の値が読めないときは増やす向きを試し、端で止まったら一度だけ反対へ振る
    public static func byStepping(start: String?, wanted: Double,
                                  step: (Step) async throws -> SliderStepResult) async throws -> SliderValueOutcome {
        var current = start
        if let now = current, SliderValueMatch.matches(current: now, wanted: wanted) {
            return SliderValueOutcome(value: now, steps: 0)
        }
        func direction(of text: String?) -> Step? {
            guard let text, let n = SliderValueMatch.number(text) else { return nil }
            return n < wanted ? .increment : .decrement
        }
        var guessed = direction(of: current) == nil
        var stepDirection = direction(of: current) ?? .increment
        var steps = 0
        while true {
            let result = try await step(stepDirection)
            steps += 1
            guard result.performed else {
                throw Failure.notPerformed(lastValue: result.value ?? current, wanted: wanted, direction: stepDirection,
                                           actions: result.actions)
            }
            guard let value = result.value else {
                throw Failure.stopped(lastValue: nil, wanted: wanted,
                                      reason: "the value could not be read after one \(stepDirection.rawValue)")
            }
            if SliderValueMatch.matches(current: value, wanted: wanted) {
                return SliderValueOutcome(value: value, steps: steps)
            }
            if value == current {
                if steps == 1, !guessed {
                    throw Failure.firstStepDidNotMove(lastValue: value, wanted: wanted, direction: stepDirection)
                }
                if guessed {
                    guessed = false
                    stepDirection = stepDirection == .increment ? .decrement : .increment
                    continue
                }
                throw Failure.stopped(lastValue: value, wanted: wanted,
                                      reason: "the value did not change (the end of the slider?)")
            }
            // 目当てをまたいだ = この送りの刻みでは止まれない(数が読めて向きが決まっている回だけ言える)
            if let before = current.flatMap(SliderValueMatch.number), let after = SliderValueMatch.number(value),
               (before - wanted) * (after - wanted) < 0 {
                throw Failure.stopped(lastValue: value, wanted: wanted,
                                      reason: "one step moves it from '\(current ?? "")' to '\(value)', past the value"
                                        + " (the slider moves in steps that skip it)")
            }
            guessed = false
            current = value
            if let next = direction(of: value) { stepDirection = next }
        }
    }

    /// **位置(0〜1)で合わせる**(XCUITest の adjust(toNormalizedSliderPosition:))。値は位置について単調と仮定し、
    /// 目当ての側の端を1回読んでから、両端の間を値で比例配分した位置を撃って狭めていく(刻みのあるスライダーは数回で当たる)。
    /// 新しい値が出なくなった(撃った位置の値が両端のどちらかと同じまま区間が変わらない)ら止める。
    /// `start` = 今の位置と値(位置は XCUITest の normalizedSliderPosition)。`resolution` = スライダーの幅の 1pt を位置にしたもの
    /// (1 / 幅 pt。これより近い2つの位置は同じタッチになるので、区間がこれより狭くなったら止める)
    public static func byPosition(start: (position: Double, value: String)?, wanted: Double, resolution: Double,
                                  probe: (Double) async throws -> String?) async throws -> SliderValueOutcome {
        var steps = 0
        func read(_ position: Double) async throws -> (Double, String, Double) {
            steps += 1
            guard let text = try await probe(position) else {
                throw Failure.stopped(lastValue: nil, wanted: wanted,
                                      reason: "the value could not be read after moving the slider to"
                                        + " \(format(position * 100))% of its length")
            }
            guard let number = SliderValueMatch.number(text) else {
                throw Failure.stopped(lastValue: text, wanted: wanted, reason: "the value has no number to compare")
            }
            return (position, text, number)
        }
        var lo: (Double, String, Double)
        var hi: (Double, String, Double)
        if let start, let n = SliderValueMatch.number(start.value) {
            if SliderValueMatch.matches(current: start.value, wanted: wanted) {
                return SliderValueOutcome(value: start.value, steps: 0)
            }
            let here = (start.position, start.value, n)
            let end = try await read(n < wanted ? 1 : 0)
            (lo, hi) = n < wanted ? (here, end) : (end, here)
        } else {
            lo = try await read(0)
            hi = try await read(1)
        }
        for edge in [lo, hi] where SliderValueMatch.matches(current: edge.1, wanted: wanted) {
            return SliderValueOutcome(value: edge.1, steps: steps)
        }
        guard min(lo.2, hi.2) < wanted, wanted < max(lo.2, hi.2) else {
            throw Failure.stopped(lastValue: hi.1, wanted: wanted,
                                  reason: "it is outside what the slider reaches ('\(lo.1)' to '\(hi.1)')")
        }
        while true {
            let span = hi.2 - lo.2
            var p = lo.0 + (wanted - lo.2) / span * (hi.0 - lo.0)
            // 比例配分が端と同じ位置になったら真ん中を撃つ(浮動小数で区間が縮まなくなるのを避ける)
            if p <= min(lo.0, hi.0) || p >= max(lo.0, hi.0) { p = (lo.0 + hi.0) / 2 }
            guard p != lo.0, p != hi.0 else {
                throw Failure.stopped(lastValue: lo.1, wanted: wanted,
                                      reason: "no position between '\(lo.1)' and '\(hi.1)' gives it")
            }
            let got = try await read(p)
            if SliderValueMatch.matches(current: got.1, wanted: wanted) {
                return SliderValueOutcome(value: got.1, steps: steps)
            }
            // 端と同じ値なら、その端を寄せる(目当ては残りの区間にある)。違う値なら目当てのどちら側かで寄せる
            if got.2 == lo.2 { lo = got }
            else if got.2 == hi.2 { hi = got }
            else if (got.2 < wanted) == (lo.2 < wanted) { lo = got } else { hi = got }
            // 区間が1pt より狭い = これ以上は別のタッチにならない。間の値は無い(刻みが目当てを飛ばす)
            if abs(hi.0 - lo.0) < resolution {
                throw Failure.stopped(lastValue: got.1, wanted: wanted,
                                      reason: "the slider goes from '\(lo.1)' to '\(hi.1)' with nothing in between")
            }
        }
    }
}

/// どの要素を動かすか(DSL の実行器と MCP の ft_set_slider_value が共有する)
public enum SliderTarget {

    public enum Resolution {
        case target(ElementInfo)
        /// 入れ物の中にスライダーが複数(範囲スライダーのつまみ等)= どれを動かすか決まらない
        case ambiguous(count: Int)
    }

    /// **id が外側の入れ物に付き、スライダーが子にある形**(Flutter の Android = `other #slider_volume` の中に `slider "50%"`)は
    /// 子へ寄せる。子に無ければそのまま(iOS の Compose・RN は XCUITest の木で other。調整できるかはブリッジが決めて断る)
    /// **木の親子に頼らず、中心が枠の中にあるスライダーも数える**(iOS の in-app の Flutter は入れ物と中のスライダーを親子で並べず、
    /// 親子だけで探すと入れ物のまま XCUITest へ回って断られた = 実測)
    public static func resolve(_ element: ElementInfo, in elements: [ElementInfo]) -> Resolution {
        guard element.type != "slider" else { return .target(element) }
        var inner = LocatorResolver.descendants(of: element, in: elements).filter { $0.type == "slider" }
        if inner.isEmpty { inner = sliders(inside: element.frame, in: elements).filter { $0.ref != element.ref } }
        if inner.count > 1 { return .ambiguous(count: inner.count) }
        return .target(inner.first ?? element)
    }

    /// 中心が `area` の中にある slider 型の要素(Android のブリッジが毎回探し直すのと同じ考え方)
    public static func sliders(inside area: FTRect, in elements: [ElementInfo]) -> [ElementInfo] {
        elements.filter {
            $0.type == "slider" && area.x <= $0.frame.centerX && $0.frame.centerX <= area.x + area.width
                && area.y <= $0.frame.centerY && $0.frame.centerY <= area.y + area.height
        }
    }

    /// 木で読める今の値。Flutter の Android はスライダーの値をラベルに出す(value は空)
    public static func currentValue(_ target: ElementInfo) -> String? {
        target.value ?? (target.type == "slider" ? target.label : nil)
    }
}

/// **どのブリッジもアクセシビリティ・XCTest の操作で動かせなかったスライダーを、帯の上のタップで合わせる**(DSL の実行器と
/// MCP が共有)。タップした位置へ値が飛ぶ作り(Material の SeekBar・Compose・Flutter・タッチだけで値を決める自前の View)で効く。
/// つまみを引かないと動かない UISlider は値が変わらず、`SliderValueLoop.byPosition` が範囲の外か「間の値が無い」で止まる。
/// 値は撃つたびに木を撮り直して読む(同じ id の要素、id が無ければ `area` の中のスライダーちょうど1つ)
public enum SliderTapPosition {
    /// `current` = 撃つ前に木で読めた値。**読めなければ1回も撃たずに断る**(タップの結果を確かめられない。iOS の XCUITest の木の
    /// Flutter のスライダーは値を出さず、確かめる前に端を叩いて 0 へ動かした = 実測)
    public static func set(driver: AppDriver, frame: FTRect, area: FTRect, identifier: String?, current: String?,
                           wanted: Double) async throws -> SliderValueOutcome {
        guard let current, SliderValueMatch.number(current) != nil else {
            throw SliderValueLoop.Failure.stopped(lastValue: current, wanted: wanted,
                                                  reason: "the slider's value is not in the tree, so tapping along it could not be"
                                                    + " checked; nothing was tapped")
        }
        if SliderValueMatch.matches(current: current, wanted: wanted) { return SliderValueOutcome(value: current, steps: 0) }
        guard frame.width > 0 else {
            throw SliderValueLoop.Failure.stopped(lastValue: current, wanted: wanted, reason: "the slider has no width to tap along")
        }
        // 端のちょうどの点は要素の外と読まれうるので、幅の 1 単位(pt / px)だけ内側を撃つ
        let inset = min(1, frame.width / 2)
        let y = frame.y + frame.height / 2
        return try await SliderValueLoop.byPosition(start: nil, wanted: wanted, resolution: 1 / frame.width) { position in
            let x = min(max(frame.x + position * frame.width, frame.x + inset), frame.x + frame.width - inset)
            try await driver.tap(x: x, y: y)
            let tree = driver.supportsCacheBypass ? try await driver.snapshot(bypassingCache: true) : try await driver.snapshot()
            return readValue(identifier: identifier, area: area, in: tree.elements)
        }
    }

    static func readValue(identifier: String?, area: FTRect, in elements: [ElementInfo]) -> String? {
        if let identifier, let same = elements.first(where: { $0.identifier == identifier }) {
            if case .target(let target) = SliderTarget.resolve(same, in: elements) { return SliderTarget.currentValue(target) }
        }
        let inside = SliderTarget.sliders(inside: area, in: elements)
        return inside.count == 1 ? SliderTarget.currentValue(inside[0]) : nil
    }
}
