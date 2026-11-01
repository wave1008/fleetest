// MCP の `ft_rotate portrait` の後に端末の回転設定を戻すかの判定。
// 元から向きが固定されていた端末(前の MCP セッションが横のまま切れた後)で元の user_rotation を
// 書き戻すと、明示された portrait を横へ取り消しながら「Rotated to portrait」と答えていた(Pixel 3a)。
// 判定は `AndroidDriver.autoRotateRestorePlan` の1箇所(adb 無しで固める)

import XCTest
@testable import FTAndroid

final class AndroidRotationRestoreTests: XCTestCase {
    /// 元が auto-rotate(accelerometer_rotation=1)なら端末の設定へ返す
    func testAutoRotateOriginalIsRestored() {
        XCTAssertEqual(AndroidDriver.autoRotateRestorePlan(original: (userRotation: 0, accelerometerRotation: 1)),
                       .restored)
        XCTAssertEqual(AndroidDriver.autoRotateRestorePlan(original: (userRotation: 1, accelerometerRotation: 1)),
                       .restored)
    }

    /// 元から固定(accelerometer_rotation=0)なら、要求された向きの固定をそのまま残す ——
    /// 元の user_rotation が横(1 / 3)でも縦(0 / 2)でも書き戻さない(縦固定の書き戻しは無害だが、
    /// 「固定されていた端末は要求された向きに固定したまま」の1規則にしておく)
    func testLockedOriginalKeepsTheExplicitPortrait() {
        for userRotation in 0...3 {
            XCTAssertEqual(AndroidDriver.autoRotateRestorePlan(
                original: (userRotation: userRotation, accelerometerRotation: 0)),
                .keptExplicitLock, "user_rotation=\(userRotation)")
        }
    }

    /// rotate(to:) を一度も呼んでいなければ何もしない
    func testNoRecordMeansNothingToRestore() {
        XCTAssertEqual(AndroidDriver.autoRotateRestorePlan(original: nil), .nothingToRestore)
    }

    /// 回転の待ちは判定の期限ではなく安全上限(宣言が回れないときは即座に断る)。値はリテラルで固定する
    func testRotationWaitConstantsArePinned() {
        XCTAssertEqual(AndroidDriver.rotationStallCapSeconds, 20)
        XCTAssertEqual(AndroidDriver.rotationRefusalConfirmations, 2)
    }

    /// 起動(monkey)が回転設定を変えたら起動前へ戻す。固定は両方の値を比べる・auto は accelerometer だけ戻す・同じなら何も書かない
    func testLaunchRestoresTheSettingsMonkeyChanged() {
        func writes(_ b: (Int, Int), _ a: (Int, Int)) -> [String] {
            AndroidDriver.rotationRestoreWrites(before: (userRotation: b.0, accelerometerRotation: b.1),
                                                after: (userRotation: a.0, accelerometerRotation: a.1))
                .map { "\($0.key)=\($0.value)" }
        }
        let lock = ["user_rotation=1", "accelerometer_rotation=0"]
        XCTAssertEqual(writes((1, 0), (1, 1)), lock)      // 固定が解けた
        XCTAssertEqual(writes((1, 0), (0, 0)), lock)      // 縦へ落ちた(accelerometer は 0 のまま)
        XCTAssertEqual(writes((1, 0), (0, 1)), lock)
        XCTAssertEqual(writes((1, 0), (1, 0)), [])
        XCTAssertEqual(writes((0, 1), (0, 0)), ["accelerometer_rotation=1"])  // auto を切られた
        XCTAssertEqual(writes((0, 1), (1, 1)), [])
        XCTAssertEqual(writes((0, 1), (0, 1)), [])
    }
}
