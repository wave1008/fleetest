import FTCore

/// `@RequiresDevice` / `@ExcludesDevice` の条件の綴り。マクロが**ソースの文字列として**読む(式は評価されない =
/// 変数・補間は書けずコンパイルエラー)ので、この型は書いたコードが型検査を通るためだけにある。
/// 綴りと意味は FTCore.DeviceCondition(`described` が同じ綴り)。
public struct FTDeviceCondition: Sendable {
    let condition: DeviceCondition

    public static let foldable = FTDeviceCondition(condition: .foldable)
    public static let physical = FTDeviceCondition(condition: .physical)
    public static let virtual = FTDeviceCondition(condition: .virtual)
    public static let homeButton = FTDeviceCondition(condition: .homeButton)

    public static func minOS(ios version: String) -> FTDeviceCondition {
        FTDeviceCondition(condition: .minOS(platform: "ios", version: version))
    }
    public static func minOS(android version: String) -> FTDeviceCondition {
        FTDeviceCondition(condition: .minOS(platform: "android", version: version))
    }
    public static func model(_ pattern: String) -> FTDeviceCondition { FTDeviceCondition(condition: .model(pattern)) }
    public static func os(_ pattern: String) -> FTDeviceCondition { FTDeviceCondition(condition: .os(pattern)) }
}
