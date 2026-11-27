// 台の性質(`DeviceTraits`)の観測の入口(この機械の台だけ・ブリッジ無し・何も起動しない)。
// 本体は `FTAndroid.DeviceTraitsObservation`(fleetest-mcp と共有)。ここは手元の simctl の控え(`IOSDeviceKindResolver`)を渡す薄い入口。
// 割り振りの前に親が1回呼ぶ。別の機械の台は `fleetest api device-traits` を remote exec で引く(ApiDeviceTraitsCommand)。
// 性質ごとの出どころの表は docs の plan(DR-237)。読めない性質は nil。注入は `TraitsInjection`(観測結果にだけ効く)。

import FTAndroid
import FTBridgeClient
import FTCore
import Foundation

enum DeviceTraitsObserver {

    /// key = プロファイルのデバイス名(1機械の中で一意)。宣言のある run だけが呼ぶ
    static func observe(entries: [DeviceMachineGrouping.CatalogEntry],
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: DeviceTraits] {
        DeviceTraitsObservation.observe(entries: entries, simctlJSON: {
            IOSDeviceKindResolver.cachedSimctlOutput(machine: nil)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }, environment: environment)
    }

    static var avdManagerTimeoutSeconds: Double { DeviceTraitsObservation.avdManagerTimeoutSeconds }

    static func deviceDefinitions(avdmanagerOutput: String) -> [String: String] {
        DeviceTraitsObservation.deviceDefinitions(avdmanagerOutput: avdmanagerOutput)
    }
}
