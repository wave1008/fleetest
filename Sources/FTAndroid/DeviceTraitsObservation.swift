// 台の性質(`DeviceTraits`)の観測の本体(ブリッジ無し・何も起動しない)。fleetest(run の割り振り)と fleetest-mcp
// (`ft_run_scenario` の台選び)が同じ関数を呼ぶ(観測を2か所に置かない)。キャッシュは持たない = 呼び手が必要なら持つ
// (常駐の MCP は呼び出しごとに読み直す)。読めない性質は nil。注入は `TraitsInjection`(観測結果にだけ効く)。

import FTBridgeClient
import FTCore
import Foundation

public enum DeviceTraitsObservation {

    /// key = プロファイルのデバイス名(1機械の中で一意)。`simctlJSON` = `simctl list -j devicetypes devices` の出力
    /// (Simulator の台があるときだけ呼ぶ = 遅延)
    public static func observe(entries: [DeviceMachineGrouping.CatalogEntry],
                               simctlJSON: () -> [String: Any]?,
                               avdDefinitions: () -> [String: String]? = { avdDeviceDefinitions() },
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: DeviceTraits] {
        var result: [String: DeviceTraits] = [:]
        let ios = entries.filter { $0.platform == "ios" }
        let android = entries.filter { $0.platform == "android" }

        let sims = ios.filter { !$0.spec.isPhysical }
        if !sims.isEmpty {
            let specs = sims.map(\.spec)
            let json = simctlJSON()
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
            let definitions = avdDefinitions()
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

    /// この機械の `simctl list -j devicetypes devices`。**終了コードを見る**(失敗 = nil。空として読まない)
    public static func localSimctlJSON() -> [String: Any]? {
        (try? Shell.run(["xcrun", "simctl", "list", "-j", "devicetypes", "devices"],
                        timeout: SimulatorCatalog.simctlTimeoutSeconds))?.outputIfSucceeded
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// avdmanager の機種定義(id → 表示名)。**終了コードを見る**(失敗の出力を機種定義として読まない)。
    /// nil = 読めなかった(機種名だけ nil になる)。機械ごとに1回(JVM の起動を台の数だけ払わない)
    public static func avdDeviceDefinitions() -> [String: String]? {
        guard let avdmanager = AndroidSDKLocator.findAVDManager(),
              let output = (try? Shell.run(AndroidSDKLocator.avdManagerCommand(avdmanager, ["list", "device"]),
                                           timeout: avdManagerTimeoutSeconds))?.outputIfSucceeded else { return nil }
        return deviceDefinitions(avdmanagerOutput: output)
    }

    /// 秒。avdmanager は JVM の起動で数秒かかる(実測の上限は取っていない = 余裕を見た値)。尽きたら機種名だけ nil(他の性質は読める)
    public static let avdManagerTimeoutSeconds: Double = 60

    /// avdmanager list device の出力(ブロック形式)→ id → 表示名。`id: NN or "id_string"` 行の後、次の id 行までの最初の `Name:` 行と対にする
    public static func deviceDefinitions(avdmanagerOutput output: String) -> [String: String] {
        var result: [String: String] = [:]
        var pendingID: String?
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let id = extractDeviceID(from: line) {
                pendingID = id
                continue
            }
            guard let id = pendingID else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Name:") else { continue }
            let name = trimmed.dropFirst("Name:".count).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            result[id] = name
            pendingID = nil
        }
        return result
    }

    /// `    id: 26 or "pixel_9_pro"` から id_string("pixel_9_pro")を取り出す
    public static func extractDeviceID(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("id:") else { return nil }
        guard let firstQuote = trimmed.firstIndex(of: "\""),
              let lastQuote = trimmed.lastIndex(of: "\""), firstQuote != lastQuote else {
            return nil
        }
        return String(trimmed[trimmed.index(after: firstQuote)..<lastQuote])
    }

    // MARK: - udid / serial 指定の台

    /// serial で指した Android の台。`emulator-*` は起動中の AVD 名から config.ini を読み、それ以外は実機(adb getprop)。
    /// AVD 名が引けなければ種別だけ確定(他は読めなかった)
    public static func serialTraits(serial: String) -> DeviceTraits {
        guard serial.hasPrefix("emulator-") else { return AndroidDeviceTraits.physicalTraits(serial: serial) }
        let avd = (try? AndroidDeviceCatalog.runningAVDs())?[serial]
        return AndroidDeviceTraits.emulatorTraits(avd: avd, deviceDefinitions: avd == nil ? nil : avdDeviceDefinitions())
    }

    /// udid で指した iOS の台の性質。ブリッジの /status が申告した udid・呼び手が名指しした udid のどちらにも使う。
    /// **udid が無い・一覧に無い台は読めなかった**(種別だけ確定。他の性質は nil)。`simctlJSON` は `simctl list -j devicetypes devices` の出力
    public static func portTraits(udid: String?, physical: Bool, simctlJSON: [String: Any]?,
                                  physicalDevices: [IOSPhysicalDeviceInfo]?) -> DeviceTraits {
        if physical {
            guard let udid, let device = physicalDevices?.first(where: { $0.udid == udid || $0.deviceCtlIdentifier == udid })
            else { return IOSPhysicalDeviceTraits.unreadable }
            return IOSPhysicalDeviceTraits.traits(of: device)
        }
        guard let udid, let simctlJSON,
              let sim = SimulatorCatalog.resolveSimulator(udid: udid, simctlJSON: simctlJSON) else {
            return SimulatorCatalog.unresolvedTraits
        }
        return SimulatorCatalog.traits(of: sim, capabilitiesPlist: SimulatorCatalog.capabilitiesPlistData(bundlePath: sim.bundlePath))
    }
}
