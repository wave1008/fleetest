// PosterBoard が落ち続けている Simulator を止める(判定は FTBridgeClient.PosterBoardCrashLoop。DS-12.4.5・DR-217)。
// 呼び口は2つ: run の開始時(`fleetest run` の ProfileRunner.prepareSupply・`fleetest api run` の同じ位置)と
// モニターの周期(fleetest の PosterBoardCrashLoopSampler)。
//
// **止めるだけで消去はしない**(アプリとデータが消える。案内の1行に消去の口を書く)。
// run か MCP が使っている台は止めず警告だけ(DeviceBooter.deviceInUseRefusal。Simulator の lease 鍵は UDID)。
// Booted(途中の状態を含む)でない台には何も撃たない・何も言わない(止まっていれば負荷は出ていない)。

import FTBridgeClient
import FTCore
import Foundation

public enum PosterBoardCrashLoopGuard {
    public enum Action: Equatable, Sendable {
        case stopped
        /// 使用中の拒否の文言(DeviceBooter.deviceInUseRefusal)
        case skippedInUse(String)
        /// 停止の失敗の文言
        case stopFailed(String)
    }

    public struct Report: Equatable, Sendable {
        public let name: String
        public let udid: String
        public let count: Int
        public let action: Action

        public init(name: String, udid: String, count: Int, action: Action) {
            self.name = name
            self.udid = udid
            self.count = count
            self.action = action
        }
    }

    /// 判定に当たった台のうち Booted の台を止める(使用中なら止めない)。戻り値 = 動いた台の報告(log にも出す)。
    /// 一覧が読めなければ何もしない(止める対象を確かめられない)。引数はテストの差し替え口
    @discardableResult
    public static func enforce(
        now: Date = Date(),
        crashes: () -> [PosterBoardCrashRecord] = { PosterBoardCrashLoop.readCrashes() },
        devices: () throws -> [SimDeviceInfo] = { try SimulatorCatalog.devices() },
        refusal: (_ name: String, _ udid: String) -> String? = { name, udid in
            DeviceBooter.deviceInUseRefusal(deviceName: name, keys: [udid], force: false,
                                            offersForce: false, leaseStateDir: nil)
        },
        stop: (_ device: SimDeviceInfo) async throws -> Void = { device in
            try await DeviceBooter.shutdownOne(
                spec: DeviceSpec(name: device.name, udid: device.udid), platform: "ios",
                repoRoot: try? RepoRoot.find(), force: false, leaseStateDir: nil, log: { _ in })
        },
        log: @Sendable (String) -> Void
    ) async -> [Report] {
        let looping = PosterBoardCrashLoop.looping(crashes: crashes(), now: now)
        guard !looping.isEmpty, let catalog = try? devices() else { return [] }
        var reports: [Report] = []
        for entry in looping {
            guard let device = catalog.first(where: { $0.udid.uppercased() == entry.udid }),
                  !device.physical, device.booted || device.transitioning else { continue }
            let action: Action
            if let refused = refusal(device.name, device.udid) {
                action = .skippedInUse(refused)
            } else {
                do {
                    try await stop(device)
                    action = .stopped
                } catch {
                    let first = error.localizedDescription.split(separator: "\n").first.map(String.init) ?? "unknown"
                    action = .stopFailed(first)
                }
            }
            let report = Report(name: device.name, udid: device.udid, count: entry.count, action: action)
            reports.append(report)
            log(message(report))
        }
        return reports
    }

    /// 出す行(英語・事実だけ)。止めた/止めなかったと理由、消去の案内
    public static func message(_ report: Report) -> String {
        let minutes = Int(PosterBoardCrashLoop.windowSeconds / 60)
        let outcome: String
        switch report.action {
        case .stopped:
            outcome = "stopped the simulator"
        case .skippedInUse(let reason):
            outcome = "did not stop it (in use): \(reason)"
        case .stopFailed(let reason):
            outcome = "tried to stop it but it did not stop: \(reason)"
        }
        return "⚠️ PosterBoard crashed \(report.count) times in the last \(minutes) min on simulator"
            + " \(report.name) (\(report.udid)) — \(outcome). If the simulator's data is corrupted it will"
            + " crash the same way on every boot; to fix it, erase it (`fleetest api wipe-device --platform ios"
            + " --udid \(report.udid)` or Wipe Data in the monitor). fleetest does not erase it automatically"
    }
}
