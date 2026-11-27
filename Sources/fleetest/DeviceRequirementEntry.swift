// 台の条件(DR-237)の入口の規則: 一覧の前に台を外す経路が一覧まで供給を待つか(`supplyStart`)・親の観測を子へ運ぶ内部フラグ
// (`--device-traits`)・`--port` の run の台の観測。`fleetest run` と `api run` は同じ関数を呼ぶ(判定を2か所に置かない)。

import ArgumentParser
import FTBridgeClient
import FTCore
import Foundation

enum DeviceRequirementEntry {

    /// 一覧の前に供給を始める経路の振る舞い
    enum SupplyStart: Equatable {
        /// 今どおり、一覧(ビルド)と並行に全台を供給する
        case parallelWithListing
        /// 一覧が出るまで供給を始めない(一覧の後に条件つきで台を絞る)
        case waitForListing
    }

    /// **判断はここだけ**(純粋関数)。ソースに宣言の文字列があり、かつ一覧の前に台を外す(明示 ID の本数で絞る・MCP の印で避ける)ときだけ待つ。
    /// どちらかが欠ければ従来どおり並行(宣言の無い回帰はビルドと供給の並行を失わない)
    static func supplyStart(sourcesDeclare: Bool, trimsBeforeListing: Bool) -> SupplyStart {
        sourcesDeclare && trimsBeforeListing ? .waitForListing : .parallelWithListing
    }

    /// 宣言の文字列(マクロの名前)。一覧(コンパイル)の前に分かる唯一の手がかり。
    /// 漏れうる(コメント・別のファイルの生成)ので、一覧の後の検算(`ProfileRunner.requireDevicesForDeclarations`)が受ける
    static let declarationMarkers = ["@RequiresDevice", "@ExcludesDevice"]

    static func sourceDeclares(_ text: String) -> Bool {
        declarationMarkers.contains { text.contains($0) }
    }

    /// プロジェクトのシナリオのソース(scenarios/ 以下の .swift)に宣言の文字列があるか
    static func sourcesDeclare(project: TestProject) -> Bool {
        guard let walker = FileManager.default.enumerator(
            at: project.scenariosDir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return false }
        for case let url as URL in walker where url.pathExtension == "swift" {
            if let text = try? String(contentsOf: url, encoding: .utf8), sourceDeclares(text) { return true }
        }
        return false
    }

    /// この機械の台(プロファイルの `machine` が手元)の性質を観測する。**宣言のある run だけが呼ぶ**(親で1回)。
    /// 別の機械の台は観測しない(= 結果に載らず、`DeviceRequirementTrim.traits` が読めなかった扱いにする)。
    /// 機械をまたぐ run の別の機械の台の観測を足す継ぎ目はここ
    static func observeLocal(_ resolved: ResolvedProfile) -> [String: DeviceTraits] {
        let entries = resolved.devices
            .filter { MachineDispatch.normalize($0.spec.machine) == nil }
            .map { DeviceMachineGrouping.CatalogEntry(platform: $0.platform, spec: $0.spec) }
        return entries.isEmpty ? [:] : DeviceTraitsObserver.observe(entries: entries)
    }

    /// run が使う観測。子は親の観測を内部フラグで受ける(`injected`)ので観測し直さない。宣言が無いなら観測しない(`[:]`)
    static func traitsForRun(injected: [String: DeviceTraits]?, resolved: ResolvedProfile,
                             declared: Bool) -> [String: DeviceTraits] {
        if let injected { return injected }
        return declared ? observeLocal(resolved) : [:]
    }

    // MARK: - `--port` の run

    /// `--port` の run の iOS の台の性質。ブリッジの /status が申告した udid で観測する。
    /// **udid が無い・一覧に無い台は読めなかった**(種別だけ確定。他の性質は nil)。`simctlJSON` は `simctl list -j devicetypes devices` の出力
    static func portTraits(udid: String?, physical: Bool, simctlJSON: [String: Any]?,
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

    /// 実機の観測(`physical` のときだけ devicectl を撃つ)・simctl の JSON は機械で1回
    static func observePort(udid: String?, physical: Bool) -> DeviceTraits {
        if physical {
            return portTraits(udid: udid, physical: true, simctlJSON: nil,
                              physicalDevices: try? IOSPhysicalDeviceCatalog.devices())
        }
        let json = IOSDeviceKindResolver.cachedSimctlOutput(machine: nil)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return portTraits(udid: udid, physical: false, simctlJSON: json, physicalDevices: nil)
    }
}

/// 親が観測した台の性質を子へ運ぶ内部フラグ(`--device-traits <JSON 1つ>`。`{"<台の名前>": DeviceTraits}`)。
/// `--foldable-model` と同じ形(子に観測を足さない)。プロファイルのファイルは書き換えない。`RunCommonOptions` には置かず
/// 両コマンドが同じ OptionGroup で持つ(ヘルプに出ない = `RunCommandFlagParityTests` の表の対象外)
enum ChildDeviceTraits {
    static let flag = "--device-traits"

    static func encode(_ traits: [String: DeviceTraits]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Codable の辞書は常に符号化できる(失敗は無い)。空は呼び手が付けない
        return String(decoding: (try? encoder.encode(traits)) ?? Data("{}".utf8), as: UTF8.self)
    }

    static func decode(_ json: String) throws -> [String: DeviceTraits] {
        do {
            return try JSONDecoder().decode([String: DeviceTraits].self, from: Data(json.utf8))
        } catch {
            throw ValidationError("--device-traits is not a valid device traits JSON: \(error.localizedDescription)")
        }
    }

    /// 子の引数へ足す2語(空なら足さない)
    static func args(_ traits: [String: DeviceTraits]) -> [String] {
        traits.isEmpty ? [] : [flag, encode(traits)]
    }
}

struct ChildDeviceTraitsOption: ParsableArguments {
    @Option(name: .customLong("device-traits"),
            help: ArgumentHelp(
                "Internal: the device traits the parent of a multi-machine run observed, as one JSON object "
                + "keyed by device name. Set by the parent; not for hand use",
                visibility: .hidden))
    var raw: String?

    /// nil = 渡されていない(自分で観測する)
    func decoded() throws -> [String: DeviceTraits]? {
        try raw.map(ChildDeviceTraits.decode)
    }
}
