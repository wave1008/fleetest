import Foundation
import FTCore

/// バリアントの無い記録(ID の記録)を扱う既存テスト用の短い形
extension LastResultsStore {
    static func failedIDs(project: TestProject, profile: String?) -> Set<String> {
        Set(failedIDs(project: project, profile: profile, declaredVariants: []).map(\.id))
    }

    static func record(project: TestProject, scenarioID: String, passed: Bool, profile: String?) {
        record(project: project, unit: ScenarioUnitKey(id: scenarioID, variant: nil), passed: passed, profile: profile,
               runID: nil, declaredVariants: [])
    }
}
