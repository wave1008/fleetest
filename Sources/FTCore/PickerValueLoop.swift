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
        // 数値で向きが決まらないときは forward を試し、端で止まったら一度だけ反対へ振る
        var direction = current.flatMap { PickerValueMatch.androidDirection(current: $0, wanted: wanted) }
        var guessed = direction == nil
        var stepDirection = direction ?? .forward
        var visited: Set<String> = current.map { [$0] } ?? []
        var steps = 0
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
