// iOS Simulator の台の解決と性質(`DeviceTraits`)の観測。入力は `simctl list -j devicetypes devices` の JSON 1回分
// (`IOSDeviceKindResolver`=対象外の回し直しの種類 と台の性質が同じ事実を共有する。simctl を2経路で読まない)。

import Foundation
import FTCore

extension SimulatorCatalog {

    /// 実行プロファイルの台1つが解決された Simulator の事実
    public struct ResolvedSimulator: Sendable, Equatable {
        public let udid: String
        public let blueprint: Blueprint
        /// デバイスタイプの名前(Xcode の Model。`iPhone Duo`)
        public let typeName: String?
        /// `iPhone` / `iPad` 等(devicetypes の productFamily)
        public let productFamily: String?
        public let bundlePath: String?
    }

    /// `specs` と添字が揃う解決結果(nil = 解決できない・実機・blueprint が無い)。純粋関数。
    /// 解決は `BridgeProvisioner` と同じ `resolve`
    public static func resolveSimulators(specs: [DeviceSpec], devices: [SimDeviceInfo],
                                         simctlJSON json: [String: Any]) -> [ResolvedSimulator?] {
        let blueprints = blueprints(simctlJSON: json)
        let types = (json["devicetypes"] as? [[String: Any]]) ?? []
        return specs.map { spec in
            guard !spec.isPhysical,
                  let info = try? resolve(spec: spec, in: devices),
                  let blueprint = blueprints[info.udid] else { return nil }
            let type = types.first { ($0["identifier"] as? String) == blueprint.deviceTypeIdentifier }
            return ResolvedSimulator(udid: info.udid, blueprint: blueprint,
                                     typeName: type?["name"] as? String,
                                     productFamily: type?["productFamily"] as? String,
                                     bundlePath: type?["bundlePath"] as? String)
        }
    }

    public static func capabilitiesPlistData(bundlePath: String?) -> Data? {
        bundlePath.flatMap { FileManager.default.contents(atPath: $0 + "/Contents/Resources/capabilities.plist") }
    }

    /// capabilities.plist の内蔵画面(`displayType == "integrated"`)の大きさ(pt = px / scale)。読めなければ nil
    static func integratedDisplaySizesPt(capabilitiesPlist data: Data) -> [(width: Double, height: Double)]? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let container = (root["capabilities"] as? [String: Any]) ?? root
        guard let displays = container["displays"] as? [[String: Any]] else { return nil }
        var sizes: [(width: Double, height: Double)] = []
        for d in displays where (d["displayType"] as? String) == "integrated" {
            guard let w = (d["width"] as? NSNumber)?.doubleValue, let h = (d["height"] as? NSNumber)?.doubleValue,
                  let scale = (d["scale"] as? NSNumber)?.doubleValue, scale > 0 else { return nil }
            sizes.append((w / scale, h / scale))
        }
        return sizes
    }

    /// 台の性質。`capabilitiesPlist` が nil(読めない)なら foldable / homeButton は nil。
    /// foldable は `FoldControl` の機種判定(内蔵画面 2 枚以上)をそのまま使う(判定を2か所に置かない)。
    /// homeButton: iPad は false / 折りたたみ機は false / iPhone は内蔵画面1枚の寸法を実行時と同じ `isHomeButtonPhoneScreen` へ
    public static func traits(of sim: ResolvedSimulator, capabilitiesPlist: Data?) -> DeviceTraits {
        let foldable = capabilitiesPlist.flatMap {
            FoldControl.isFoldableModel(integratedDisplayCount: FoldControl.integratedDisplayCount(capabilitiesPlist: $0))
        }
        var homeButton: Bool?
        switch sim.productFamily {
        case "iPad": homeButton = false
        case "iPhone":
            if foldable == true {
                homeButton = false
            } else if let plist = capabilitiesPlist, let sizes = integratedDisplaySizesPt(capabilitiesPlist: plist),
                      sizes.count == 1 {
                homeButton = BridgeAPI.isHomeButtonPhoneScreen(width: sizes[0].width, height: sizes[0].height)
            }
        default: homeButton = nil
        }
        return DeviceTraits(platform: "ios", physical: false, foldable: foldable, homeButton: homeButton,
                            osVersion: osName(runtimeIdentifier: sim.blueprint.runtimeIdentifier),
                            model: sim.typeName)
    }

    /// 解決できなかった Simulator の性質(種別だけ確定・残りは読めなかった)
    public static let unresolvedTraits = DeviceTraits(platform: "ios", physical: false)
}
