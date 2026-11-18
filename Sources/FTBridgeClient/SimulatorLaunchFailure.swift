// SimulatorLaunchFailure.swift
// Simulator でランナーを起動できなかった理由を xcodebuild のログから拾う(実機は IOSDeviceTransport.runnerFailureReason)。
// 読むのは xcodebuild の決まった書式の行だけ(`Finished with error: …` と `Failure Reason: …`)

import Foundation

extension BridgeLauncher {
    /// 例(M1Max の iPhone 17e・SpringBoard が落ちた回): "Simulator device failed to launch com.example.ftrunner.uitests.xctrunner.
    /// (The system shell probably crashed.)"。どちらの行も無ければ nil
    static func simulatorLaunchFailureReason(inLog text: String) -> String? {
        func firstValue(after marker: String) -> String? {
            for line in text.split(separator: "\n") {
                guard let range = line.range(of: marker) else { continue }
                let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
            return nil
        }
        let finished = firstValue(after: "Finished with error: ")
        let reason = firstValue(after: "Failure Reason: ")
        switch (finished, reason) {
        case let (f?, r?): return "\(f) (\(r))"
        case let (f?, nil): return f
        case let (nil, r?): return r
        default: return nil
        }
    }
}
