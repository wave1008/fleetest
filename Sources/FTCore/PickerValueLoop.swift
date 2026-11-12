// Android の NumberPicker を値で合わせるホスト側のループ(ブリッジは1段ずつ送って値を読み返すだけ)。
// 止める条件は観測できる事象だけ(回数の定数を置かない): 一致した / 送れなかった・値が読めなかった /
// 値が動かなかった(端) / 既出の値に戻った(一周)。値の集合は有限なので必ず終わる。
// 1回撃つごとに読む(届いたか分からない送りを重ねない)。

import Foundation

public struct PickerStepResult: Sendable, Equatable {
    public var performed: Bool
    public var value: String?
    public init(performed: Bool, value: String?) {
        self.performed = performed
        self.value = value
    }
}

/// 合わせた後に読めた値と、送った回数(iOS は adjust に渡した候補の数)
public struct PickerValueOutcome: Sendable, Equatable {
    public var value: String
    public var steps: Int
    public init(value: String, steps: Int) {
        self.value = value
        self.steps = steps
    }
}

public enum PickerValueLoop {

    public typealias Outcome = PickerValueOutcome

    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        /// 値が一致しないまま止まった。`lastValue` = 止まったときに読めていた値、`reason` = 止まった事実
        case stopped(lastValue: String?, wanted: String, reason: String)

        public var description: String {
            switch self {
            case let .stopped(last, wanted, reason):
                return "the picker stopped at \(last.map { "'\($0)'" } ?? "an unreadable value"), not '\(wanted)': \(reason)"
            }
        }
    }

    /// `start` = 呼び手が持っている現在の値(木から。nil = 読めていない)。`step` = ブリッジへ1段送って読み直す
    public static func run(start: String?, wanted: String,
                           step: (PickerValueMatch.Step) async throws -> PickerStepResult) async throws -> Outcome {
        var current = start
        if let now = current, PickerValueMatch.matches(current: now, wanted: wanted) {
            return Outcome(value: now, steps: 0)
        }
        var steps = 0
        // **一周する作りのホイールは逆向きが近いことがある**(分の 53 → 00 は前へ 7 段・後ろへ 53 段)。一周するかは端にいるとき
        // しか木から読めない(隣の行の文字は前後の値だけ)ので、数値の向きの段数 d の半分までは逆向きを試し、値が端から
        // 反対の端へ飛んだ(一周した)のが見えたら進み続ける。見えなければ戻って数値の向きで合わせる。
        // **外れたときの上乗せは試した段数の往復 = d 以下**(最悪でも数値の向きだけの2倍)。試す段数が2未満なら試さない
        // (1段で一周が見えるのは値が数個のホイールだけ)。実測(Google マップ・分の 00 合わせ): 後ろへ約50段で 17.3 秒
        if let now = current, let direction = PickerValueMatch.androidDirection(current: now, wanted: wanted),
           let from = PickerValueMatch.leadingInteger(now), let target = PickerValueMatch.numericTarget(wanted) {
            let budget = abs(target - from) / 2
            if budget >= 2 {
                let probe: PickerValueMatch.Step = direction == .forward ? .backward : .forward
                var last = from
                var wrapped = false
                var tried = 0
                probing: while wrapped || tried < budget {
                    let result = try await step(probe)
                    steps += 1
                    tried += 1
                    // 送れなかった(撃っていない)・動かない(端)= 一周しない側の端。数値の向きへ戻る
                    guard result.performed else { break probing }
                    // 読めなければ次を撃たない(届いたか分からない送りを重ねない = 下のループと同じ)
                    guard let value = result.value else {
                        throw Failure.stopped(lastValue: nil, wanted: wanted,
                                              reason: "the value could not be read after scrolling \(probe.rawValue)")
                    }
                    guard value != current, let number = PickerValueMatch.leadingInteger(value) else {
                        current = value
                        break probing
                    }
                    current = value
                    if PickerValueMatch.matches(current: value, wanted: wanted) {
                        return Outcome(value: value, steps: steps)
                    }
                    if !wrapped, probe == .forward ? number < last : number > last { wrapped = true }
                    // 一周した後に目当てを通り過ぎた(刻みが合わない等)= 数値の向きで合わせ直す
                    if wrapped, probe == .forward ? number > target : number < target { break probing }
                    last = number
                }
            }
        }
        // 数値で向きが決まらないときは forward を試し、端で止まったら一度だけ反対へ振る
        var direction = current.flatMap { PickerValueMatch.androidDirection(current: $0, wanted: wanted) }
        var guessed = direction == nil
        var stepDirection = direction ?? .forward
        var visited: Set<String> = current.map { [$0] } ?? []
        while true {
            let result = try await step(stepDirection)
            steps += 1
            guard result.performed else {
                throw Failure.stopped(lastValue: result.value ?? current, wanted: wanted,
                                      reason: "the bridge could not scroll the picker \(stepDirection.rawValue)")
            }
            guard let value = result.value else {
                throw Failure.stopped(lastValue: nil, wanted: wanted,
                                      reason: "the value could not be read after scrolling \(stepDirection.rawValue)")
            }
            if PickerValueMatch.matches(current: value, wanted: wanted) {
                return Outcome(value: value, steps: steps)
            }
            let unchanged = value == current
            if unchanged || visited.contains(value) {
                if unchanged && guessed {
                    guessed = false
                    stepDirection = stepDirection == .forward ? .backward : .forward
                    visited = [value]
                    current = value
                    continue
                }
                throw Failure.stopped(lastValue: value, wanted: wanted,
                                      reason: unchanged ? "the value did not change (end of the list?)"
                                                        : "the picker went all the way round without reaching it")
            }
            visited.insert(value)
            current = value
        }
    }
}
