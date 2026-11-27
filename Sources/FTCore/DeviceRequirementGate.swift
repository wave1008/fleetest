// 機械の中の run(キュー・ドレイン・afterAll)が使う、台の条件(DR-237)の判定の入口。
// 「台が条件に合うか」は `permits` / `fit` の1箇所だけ(中身は `DeviceRequirementMatch.fit`)。キューの取り出しと回し直しの
// 試した扱いも、ここを呼ぶ。宣言なし・空の条件は台の性質を読まずに常に合う(従来の挙動と同一)。

import Foundation

public enum DeviceRequirementGate {
    /// 宣言なし・空 = `.fits`(性質を見ない)。宣言があるのに台の性質が無い(観測していない)ときは読めなかった扱い
    public static func fit(_ requirements: DeviceRequirementSet?, traits: DeviceTraits?) -> DeviceRequirementMatch.Fit {
        guard let requirements, !requirements.isEmpty else { return .fits }
        guard let traits else { return .unreadable(traits: ["traits"]) }
        return DeviceRequirementMatch.fit(requirements, traits)
    }

    /// 配ってよいか(`.fits` だけ。合わない台も読めなかった台も配らない)
    public static func permits(_ requirements: DeviceRequirementSet?, traits: DeviceTraits?) -> Bool {
        fit(requirements, traits: traits) == .fits
    }

    /// 合う台が無いときの結論
    public enum Conclusion: Equatable, Sendable {
        /// 読めなかった台があり、合う台が無い(赤)。reason = 失敗の理由(事実だけ)
        case failed(reason: String)
        /// 全台が読めて、どれも合わない(緑・対象外)。reason = 条件と「合う台が無い」事実
        case skipped(reason: String)
    }

    /// 宣言されたが run に参加しなかった台(供給失敗・合流しなかった)。traits nil = 観測していない(読めなかった扱い)
    public typealias AbsentDevice = (id: String, traits: DeviceTraits?)

    /// 結論を決める。**参加した台のどれかが合えば nil**(結論ではなくドレインの通常の理由)・参加した台が1つも無いときも nil。
    /// 読めなかった台が1台でもあれば失敗(読めなかった台を「合わない」に丸めない = DR-237・DR-1)。
    /// **`absent` = 参加しなかった台**。合う台・読めなかった台が居れば緑にしない(合う台が欠けただけで「合う台が無い」とは言えない)。
    /// 緑にできるのは、run が使う全台(参加した台 + 参加しなかった台)が読めて、どれも合わないときだけ。
    /// `perDevice` = broadcast(1レーン1キュー)。文言だけが違う
    public static func conclusion(_ requirements: DeviceRequirementSet, lanes: [DeviceRequirementMatch.Device],
                                  absent: [AbsentDevice] = [], perDevice: Bool = false) -> Conclusion? {
        guard !lanes.isEmpty else { return nil }
        let part = DeviceRequirementMatch.partition(requirements, devices: lanes)
        guard part.fits.isEmpty else { return nil }
        let conditions = describe(requirements)
        var facts = DeviceRequirementMatch.noMatchFacts(requirements, devices: lanes)
        var absentBlocks = false
        for device in absent {
            switch fit(requirements, traits: device.traits) {
            case .fits:
                absentBlocks = true
                facts.append("\(device.id): fits but did not take part in the run")
            case .unreadable(let traits):
                absentBlocks = true
                facts.append("\(device.id): unreadable (\(traits.joined(separator: ", "))) and did not take part in the run")
            case .unfit(let reasons):
                facts.append("\(device.id): unfit (\(reasons.joined(separator: "; "))) and did not take part in the run")
            }
        }
        let joined = facts.joined(separator: "; ")
        if !part.unreadable.isEmpty || absentBlocks {
            let lead = part.unreadable.isEmpty
                ? "a device that may match the declared device conditions did not take part in the run"
                : "could not read the device traits needed for the declared device conditions"
            return .failed(reason: "\(lead) (\(conditions)): \(joined)")
        }
        return .skipped(reason: perDevice
            ? "not applicable (conditions not met): \(conditions) — \(joined)"
            : "not applicable: no matching device for \(conditions) — \(joined)")
    }

    /// DSL の書き方どおりの条件の一覧(`required: …; excluded: …`)
    public static func describe(_ set: DeviceRequirementSet) -> String {
        var parts: [String] = []
        if !set.required.isEmpty { parts.append("required: " + set.required.map(\.described).joined(separator: ", ")) }
        if !set.excluded.isEmpty { parts.append("excluded: " + set.excluded.map(\.described).joined(separator: ", ")) }
        return parts.joined(separator: "; ")
    }

    /// クラスの全テストが共通に持つ条件(クラス宣言の和の近似)。1本でも宣言が無ければ空 = 縛らない。
    /// 一覧の `ScenarioInfo.deviceRequirements` はクラスとテストの和でクラス単独の組を運ばないので、afterAll の宛先はここから導く
    /// (全テストが同じテスト単位の条件を持つクラスでは、その分だけ厳しく選ぶ)
    public static func classLevel(of sets: [DeviceRequirementSet?]) -> DeviceRequirementSet {
        guard let first = sets.first, let head = first else { return DeviceRequirementSet() }
        var required = head.required, excluded = head.excluded
        for case let set? in sets.dropFirst() {
            required.removeAll { !set.required.contains($0) }
            excluded.removeAll { !set.excluded.contains($0) }
        }
        if sets.contains(where: { $0 == nil }) { return DeviceRequirementSet() }
        return DeviceRequirementSet(required: required, excluded: excluded)
    }

    /// afterAll を走らせる台の選び方
    public enum AfterAllChoice: Equatable, Sendable {
        /// 候補(仕事を終えた台)の添字
        case lane(Int)
        /// 走らせる台が無い。reason = 合う台が無かった事実(nil = 条件に依らず候補が無い)
        case none(reason: String?)
    }

    /// 仕事を最後まで終えた台(終えた順)のうち、そのクラスの OS で条件に合う最初の台。
    /// 合う台が無ければ、台が読めなかったか(失敗)・全部読めて合わないか(対象外)を理由に言う(afterAll の結果は results に載らないのでログの1行)
    public static func chooseAfterAllLane(requirements: DeviceRequirementSet, platforms: Set<String>,
                                          lanes: [(id: String, platform: String, traits: DeviceTraits)]) -> AfterAllChoice {
        let eligible = lanes.enumerated().filter { platforms.isEmpty || platforms.contains($0.element.platform) }
        guard !eligible.isEmpty else { return .none(reason: nil) }
        if let hit = eligible.first(where: { permits(requirements, traits: $0.element.traits) }) { return .lane(hit.offset) }
        let devices = eligible.map { (id: $0.element.id, traits: $0.element.traits) }
        switch conclusion(requirements, lanes: devices) {
        case .failed(let reason)?, .skipped(let reason)?: return .none(reason: reason)
        case nil: return .none(reason: nil)
        }
    }

    /// 回し直しの「試した扱い」に足す台: `among` のうち、この条件に合わない台(配られないので試せない)
    public static func ineligible(_ requirements: DeviceRequirementSet?, among lanes: Set<String>,
                                  traits: [String: DeviceTraits]) -> Set<String> {
        guard let requirements, !requirements.isEmpty else { return [] }
        return lanes.filter { !permits(requirements, traits: traits[$0]) }
    }
}
