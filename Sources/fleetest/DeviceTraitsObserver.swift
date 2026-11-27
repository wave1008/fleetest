// 台の性質(`DeviceTraits`)の観測の入口(この機械の台だけ・ブリッジ無し・何も起動しない)。
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
        var result: [String: DeviceTraits] = [:]
        let ios = entries.filter { $0.platform == "ios" }
        let android = entries.filter { $0.platform == "android" }

        let sims = ios.filter { !$0.spec.isPhysical }
        if !sims.isEmpty {
            let specs = sims.map(\.spec)
            let json = IOSDeviceKindResolver.cachedSimctlOutput(machine: nil)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            // 供給と同じ `SimulatorCatalog.devices()`(simctl は上の1回だけ。読めなければ simctl の JSON から)
            let devices = (try? SimulatorCatalog.devices()) ?? json.flatMap { SimulatorCatalog.devices(simctlJSON: $0) } ?? []
            let resolved = json.map { SimulatorCatalog.resolveSimulators(specs: specs, devices: devices, simctlJSON: $0) }
                ?? Array(repeating: nil, count: specs.count)
            for (entry, sim) in zip(sims, resolved) {
                result[entry.name] = sim.map {
                    SimulatorCatalog.traits(of: $0, capabilitiesPlist: SimulatorCatalog.capabilitiesPlistData(bundlePath: $0.bundlePath))
                } ?? SimulatorCatalog.unresolvedTraits
            }
        }

        let phones = ios.filter { $0.spec.isPhysical }
        if !phones.isEmpty {
            let listed = try? IOSPhysicalDeviceCatalog.devices()
            for entry in phones {
                let declared = entry.spec.udid ?? ""
                let device = listed?.first { !declared.isEmpty && ($0.udid == declared || $0.deviceCtlIdentifier == declared) }
                result[entry.name] = device.map(IOSPhysicalDeviceTraits.traits(of:)) ?? IOSPhysicalDeviceTraits.unreadable
            }
        }

        let emulators = android.filter { !$0.spec.isPhysical }
        if !emulators.isEmpty {
            let definitions = avdDeviceDefinitions()
            for entry in emulators {
                result[entry.name] = AndroidDeviceTraits.emulatorTraits(avd: entry.spec.avd, deviceDefinitions: definitions)
            }
        }
        for entry in android where entry.spec.isPhysical {
            result[entry.name] = AndroidDeviceTraits.physicalTraits(serial: entry.spec.serial)
        }

        return result.reduce(into: [:]) { out, pair in
            out[pair.key] = TraitsInjection.apply(pair.value, key: pair.key, environment: environment)
        }
    }

    /// avdmanager の機種定義(id → 表示名)。**終了コードを見る**(失敗の出力を機種定義として読まない)。
    /// nil = 読めなかった(機種名だけ nil になる)。機械ごとに1回(JVM の起動を台の数だけ払わない)
    static func avdDeviceDefinitions() -> [String: String]? {
        guard let avdmanager = AndroidSDKLocator.findAVDManager(),
              let output = (try? Shell.run(AndroidSDKLocator.avdManagerCommand(avdmanager, ["list", "device"]),
                                           timeout: avdManagerTimeoutSeconds))?.outputIfSucceeded else { return nil }
        return deviceDefinitions(avdmanagerOutput: output)
    }

    /// 秒。avdmanager は JVM の起動で数秒かかる(実測の上限は取っていない = 余裕を見た値)。尽きたら機種名だけ nil(他の性質は読める)
    static let avdManagerTimeoutSeconds: Double = 60

    static func deviceDefinitions(avdmanagerOutput: String) -> [String: String] {
        ApiDeviceCatalogCommand.parseDeviceDefinitions(avdmanagerOutput)
            .reduce(into: [:]) { $0[$1.id] = $1.name }
    }
}
