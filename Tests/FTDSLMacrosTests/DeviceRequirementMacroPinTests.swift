import FTCore
import XCTest
@testable import FTDSLMacros

/// マクロ側の宣言の検査(`DeviceConditionSpec`)は FTCore.DeviceCondition の写し(マクロは FTCore に依存できない)。
/// 同じ表を両方へ通して、判定と文言が割れたら落とす
final class DeviceRequirementMacroPinTests: XCTestCase {
    private static let table: [(DeviceConditionSpec, DeviceCondition)] = [
        (.foldable, .foldable), (.physical, .physical), (.virtual, .virtual), (.homeButton, .homeButton),
        (.minOS(platform: "ios", version: "18"), .minOS(platform: "ios", version: "18")),
        (.minOS(platform: "android", version: "17.4"), .minOS(platform: "android", version: "17.4")),
        (.minOS(platform: "ios", version: "18.x"), .minOS(platform: "ios", version: "18.x")),
        (.minOS(platform: "ios", version: ""), .minOS(platform: "ios", version: "")),
        (.minOS(platform: "ios", version: "18."), .minOS(platform: "ios", version: "18.")),
        (.minOS(platform: "windows", version: "10"), .minOS(platform: "windows", version: "10")),
        (.model("iPhone 18*"), .model("iPhone 18*")),
        (.model("*Pro*||iPad*"), .model("*Pro*||iPad*")),
        (.model("*"), .model("*")),
        (.model("**"), .model("**")),
        (.model(""), .model("")),
        (.model("a||"), .model("a||")),
        (.model("||a"), .model("||a")),
        (.model("  "), .model("  ")),
        (.model("\u{200B}*"), .model("\u{200B}*")),
        (.model("\u{200B}"), .model("\u{200B}")),
        (.model("*\u{FEFF}*"), .model("*\u{FEFF}*")),
        (.model("* *"), .model("* *")),
        (.os("iOS 27*"), .os("iOS 27*")),
        (.os("iOS 27*||Android 15"), .os("iOS 27*||Android 15")),
        (.os("17*"), .os("17*")),
        (.os("iOS 27*||17"), .os("iOS 27*||17")),
        (.os("ios 27"), .os("ios 27")),
        (.os("*"), .os("*")),
        (.os(""), .os("")),
    ]

    func test宣言の検査はFTCoreと判定も文言も同じ() {
        for (spec, core) in Self.table {
            XCTAssertEqual(spec.declarationError, DeviceCondition.declarationError(core), "\(spec.described)")
        }
    }

    func test綴りはFTCoreのdescribedと同じ() {
        for (spec, core) in Self.table {
            XCTAssertEqual(spec.described, core.described)
        }
    }

    func test矛盾の文言はFTCoreと同じ() {
        let cases: [([DeviceConditionSpec], [DeviceConditionSpec], [DeviceCondition], [DeviceCondition])] = [
            ([.physical, .virtual], [], [.physical, .virtual], []),
            ([.foldable], [.foldable], [.foldable], [.foldable]),
            ([.minOS(platform: "ios", version: "18"), .model("a")], [.model("a")],
             [.minOS(platform: "ios", version: "18"), .model("a")], [.model("a")]),
            ([.physical], [.foldable], [.physical], [.foldable]),
        ]
        for (r, e, cr, ce) in cases {
            let macro = TestClassMacro.deviceContradictions(DeviceDeclaration(required: r, excluded: e))
            XCTAssertEqual(macro, DeviceRequirementSet(required: cr, excluded: ce).contradictions)
        }
    }
}
