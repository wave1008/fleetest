import FTDSL
import XCTest

@TestClass
@RequiresDevice(.physical)
@ExcludesDevice(.model("iPad*||Pixel Fold"))
class DeviceRequirementDescriptorFixture {
    @Test("a")
    @RequiresDevice(.foldable, .minOS(ios: "18"), .minOS(android: "15"))
    @ExcludesDevice(.homeButton, .os("iOS 17*||Android 14"), .virtual)
    func S0010() {}

    @Test("b")
    func S0020() {}
}

/// @RequiresDevice / @ExcludesDevice の綴りが型検査を通り、マクロの生成物が descriptor → ScenarioInfo へ届く(DR-237)
final class DeviceRequirementDescriptorTests: XCTestCase {
    func test宣言は合わせた形で一覧の行に載る() {
        let infos = DeviceRequirementDescriptorFixture.ftDescriptor.scenarioInfos
        XCTAssertEqual(infos[0].deviceRequirements, DeviceRequirementSet(
            required: [.physical, .foldable, .minOS(platform: "ios", version: "18"), .minOS(platform: "android", version: "15")],
            excluded: [.model("iPad*||Pixel Fold"), .homeButton, .os("iOS 17*||Android 14"), .virtual]))
        XCTAssertEqual(infos[1].deviceRequirements,
                       DeviceRequirementSet(required: [.physical], excluded: [.model("iPad*||Pixel Fold")]))
    }
}
