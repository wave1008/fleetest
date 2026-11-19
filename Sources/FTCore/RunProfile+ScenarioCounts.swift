// RunProfile+ScenarioCounts.swift
// 台数の見積りのうち、クラスの寄せ方(RR-8.3)を数える部分。OS の振り分けは RunProfile.swift の scenarioCounts(platforms:) を通す

extension ResolvedProfile {
    /// 一覧が確定したシナリオから数える台数の見積り。1台に寄せるクラス(`@RunOnSingleDevice` / `@RunInOrder`)は本数に関わらず
    /// 1台ぶん(そのクラスは1台でしか走らない = 本数ぶん用意すると残りは起動しただけで使われない。RR-8.3)。
    /// 寄せるクラスは OS の宣言がそろっている(マクロが断る)ので、最初のメンバーの platform で数える
    public func scenarioCounts(_ scenarios: [ScenarioInfo]) -> (ios: Int, android: Int) {
        var boundClasses = Set<String>()
        let platforms = scenarios.compactMap { info -> String?? in
            guard info.placement?.bindsDevice == true else { return .some(info.platform) }
            return boundClasses.insert(ClassPlacementRules.className(of: info.id)).inserted ? .some(info.platform) : nil
        }
        return scenarioCounts(platforms: platforms)
    }
}
