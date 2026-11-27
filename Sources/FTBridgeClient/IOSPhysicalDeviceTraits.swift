// iOS 実機の台の性質(`DeviceTraits`)の観測。devicectl の一覧だけから導く(ブリッジ無し)。
// 読めない性質は nil(空文字・`"iOS"` だけを値にしない)。

import Foundation
import FTCore

public enum IOSPhysicalDeviceTraits {

    /// ホームボタンのある iPhone の productType(6s〜8・SE 1〜3)。**シミュレータと違い画面寸法の表
    /// (`isHomeButtonPhoneScreen`)を使わないのは例外**: 実機はブリッジの前(割り振りの時点)で、
    /// devicectl は画面の寸法を返さない。閉じた集合なので、新機種は表に無ければ false(Face ID)で読む
    static let homeButtonIPhoneProductTypes: Set<String> = [
        "iPhone8,1", "iPhone8,2",          // 6s / 6s Plus
        "iPhone8,4",                       // SE (1st)
        "iPhone9,1", "iPhone9,3",          // 7
        "iPhone9,2", "iPhone9,4",          // 7 Plus
        "iPhone10,1", "iPhone10,4",        // 8
        "iPhone10,2", "iPhone10,5",        // 8 Plus
        "iPhone12,8",                      // SE (2nd)
        "iPhone14,6",                      // SE (3rd)
    ]

    /// X(Face ID)。世代が 10 でも表に無い iPhone10,x のうちホームボタンの無い2機種
    private static let faceIDGeneration10: Set<String> = ["iPhone10,3", "iPhone10,6"]

    /// nil = 判定できない(productType が無い・iPhone / iPad 以外)。iPad は false(確定)。
    /// iPhone: 表にあれば true・世代 11 以降か X なら false・それ以外(6s より前など = 表に無い古い世代)は nil
    public static func homeButton(productType: String?) -> Bool? {
        guard let productType else { return nil }
        if productType.hasPrefix("iPad") { return false }
        guard productType.hasPrefix("iPhone") else { return nil }
        if homeButtonIPhoneProductTypes.contains(productType) { return true }
        if faceIDGeneration10.contains(productType) { return false }
        let generation = productType.dropFirst("iPhone".count).split(separator: ",").first.flatMap { Int($0) }
        guard let generation, generation >= 10 else { return nil }
        return false
    }

    /// devicectl の osVersionNumber("26.6.2")→ `"iOS 26.6.2"`。無ければ nil
    public static func osVersion(osVersionNumber: String?) -> String? {
        guard let v = osVersionNumber, DeviceVersion.parse(v) != nil else { return nil }
        return "iOS " + v
    }

    public static func traits(of device: IOSPhysicalDeviceInfo) -> DeviceTraits {
        DeviceTraits(platform: "ios", physical: true, foldable: false,
                     homeButton: homeButton(productType: device.productType),
                     osVersion: osVersion(osVersionNumber: device.osVersionNumber),
                     model: device.marketingName)
    }

    /// 実機が devicectl の一覧に無い(接続も記録も無い)ときの性質: 種別だけ確定・残りは読めなかった
    public static let unreadable = DeviceTraits(platform: "ios", physical: true)
}
