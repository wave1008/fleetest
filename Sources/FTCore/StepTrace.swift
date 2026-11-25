// ステップの「判定の足跡」(step trace)。判定が分かれた直後の一次情報(数値・枠・id・Bool)だけを構造化して残す。
//
// 結果 JSON は事実だけ(推測・分類を書かない。DR-1)。欄が無い = 測っていない(省略可の欄。DR-75)ので、
// 互換の読み替えは置かず、プロトコル版も上げない。
// 運搬経路: StepExecutor.traceThisStep → StepOutcome.trace → FTRuntime.recordStep → ScenarioEvent.trace
//   → ScenarioRunner.stepResult(from:) → StepResult.trace / ScenarioRecordBuilder → TimelineStepRecord.trace・FailedStepRecord.trace

import Foundation

/// 足跡の段の名前。**rawValue は永続化される(結果 JSON)ので一度出したものは変えない**。
/// 各段の facts のキーの意味は docs/results-json.md の「trace」
public enum StepTraceStage: String, CaseIterable, Sendable {
    /// `liftCoveredTarget`(キーボード・固定帯に覆われた対象を持ち上げる判定)の分かれ目
    case keyboardCoverLift = "keyboard-cover-lift"
    /// 容器の外か(`ContainerGeometry.isOutsideContainer`)の判定の結果
    case containerOutside = "container-outside"
    /// スクロール探索の終端(止まった理由・払いの本数・最後の1本の種類)
    case scrollSearchEnd = "scroll-search-end"
    /// 可視性検証で FM が近い外れと判定したときの OCR 分岐
    case ocrNearMiss = "ocr-near-miss"
    /// 上限を超えて捨てた足跡の数(`dropped`)。`StepTraceBuffer` だけが置く
    case traceTruncated = "trace-truncated"
}

/// 足跡の上限。根拠: 結果 JSON は run ごとに全ステップの timeline を持つので、1ステップの足跡が
/// 膨らむと1シナリオの大きさが線形に増える。単位は entry 数 / 文字数(Swift の Character)。
/// 尽きたとき: 古い entry から捨て、先頭に `trace-truncated`(`dropped=<捨てた数>`)を1つ置く(実 entry は最大 `maxEntries` + この1つ)。
/// 値は末尾を `…` で切る(切った後の長さが `maxValueLength` ちょうど)
public enum StepTraceLimits {
    public static let maxEntries = 16
    public static let maxValueLength = 240
}

public struct StepTraceEntry: Codable, Sendable, Equatable {
    public let stage: String
    public let facts: [String: String]

    public init(stage: String, facts: [String: String]) {
        self.stage = stage
        self.facts = facts
    }

    // キーの順序は書き手の `.sortedKeys` に任せる(RunResultsStore・ScenarioEvent の両方が指定。JSONEncoder は挿入順を保たない)
}

/// 1ステップ分の足跡の累積器(上限の処理を1箇所に閉じる)。
public struct StepTraceBuffer: Sendable {
    private(set) var entries: [StepTraceEntry] = []
    private(set) var dropped = 0

    public init() {}

    public mutating func append(_ stage: StepTraceStage, _ facts: KeyValuePairs<String, String>) {
        var map: [String: String] = [:]
        for (key, value) in facts { map[key] = value }
        append(stage, facts: map)
    }

    /// 上限を超えたら**古い方から**捨てる(赤を決めたのは最後の試み = 待ちの間に探索を繰り返すステップでは後ろが要る)
    public mutating func append(_ stage: StepTraceStage, facts: [String: String]) {
        if entries.count >= StepTraceLimits.maxEntries {
            entries.removeFirst()
            dropped += 1
        }
        entries.append(StepTraceEntry(stage: stage.rawValue, facts: facts.mapValues(Self.clipped)))
    }

    /// 結果へ載せる形。捨てた分があれば先頭に `trace-truncated`(捨てたのは最初の `dropped` 件)を置く
    public func finished() -> [StepTraceEntry] {
        guard dropped > 0 else { return entries }
        return [StepTraceEntry(stage: StepTraceStage.traceTruncated.rawValue,
                               facts: ["dropped": String(dropped)])] + entries
    }

    static func clipped(_ value: String) -> String {
        guard value.count > StepTraceLimits.maxValueLength else { return value }
        return String(value.prefix(StepTraceLimits.maxValueLength - 1)) + "…"
    }
}

/// 足跡の facts の書式(枠・Bool)。呼び手ごとに書式が割れないよう1箇所に置く
public enum StepTraceFormat {
    /// `x,y wxh`(小数1桁。ft_snapshot の単位のまま)
    public static func frame(_ rect: FTRect?) -> String {
        guard let rect else { return "none" }
        return "\(number(rect.x)),\(number(rect.y)) \(number(rect.width))x\(number(rect.height))"
    }

    /// 非有限・Int に収まらない値は `Int()` が落ちるので書かない(枠はブリッジの申告のまま来る)
    public static func number(_ value: Double) -> String {
        guard value.isFinite else { return "?" }
        if let exact = Int(exactly: value) { return String(exact) }
        return String(format: "%.1f", value)
    }

    public static func bool(_ value: Bool) -> String { value ? "true" : "false" }
}

/// FTCore の外(FTFoundationModels)の判定の分かれ目を足跡へ載せる口。`ReplayDelegate` の戻りの形(平坦なタプル)を
/// 変えずに運ぶため、呼び手(StepExecutor)が task-local に箱を束ね、呼ばれた側が `record` する。
/// 束ねていない呼び出し(MCP など)では何もしない
public enum StepTraceSink {
    @TaskLocal public static var current: LockedValue<[StepTraceItem]>?

    public static func record(_ stage: StepTraceStage, _ facts: [String: String]) {
        current?.withLock { $0.append(StepTraceItem(stage: stage, facts: facts)) }
    }

    /// `operation` の中で記録された足跡を集めて返す
    public static func collecting<R>(_ operation: () async -> R) async -> (result: R, items: [StepTraceItem]) {
        let box = LockedValue<[StepTraceItem]>([])
        let result = await $current.withValue(box) { await operation() }
        return (result, box.value)
    }
}

public struct StepTraceItem: Sendable {
    public let stage: StepTraceStage
    public let facts: [String: String]
    public init(stage: StepTraceStage, facts: [String: String]) {
        self.stage = stage
        self.facts = facts
    }
}
