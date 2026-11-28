// FMDoctor の失敗の文言: 常駐(fleetest api fm-serve)に届かなかった回に「モデル資産」の帰属を言わない
// (モデルには訊けていない。検知の入力から導けない帰属を文言に入れない)

@testable import FTFoundationModels
import XCTest

final class FMDoctorMessageTests: XCTestCase {

    func testUnreachableDoesNotBlameTheModelAssets() {
        let text = FMDoctor.textLiveFailureDetail(reachedTheModel: false, error: "connect refused")
        XCTAssertTrue(text.contains("could not be reached"), text)
        XCTAssertTrue(text.contains("the model was not asked"), text)
        XCTAssertFalse(text.contains("model assets"), text)
        XCTAssertTrue(text.contains("connect refused"), "一次情報(エラー)はそのまま残す")
        let vision = FMDoctor.visionLiveFailureDetail(reachedTheModel: false, error: nil)
        XCTAssertTrue(vision.contains("could not be reached"), vision)
        XCTAssertTrue(vision.contains("disabled"), "届かなくても guard が無効になる事実は言う")
    }

    func testRealFailureStillPointsAtTheModelAssets() {
        let text = FMDoctor.textLiveFailureDetail(reachedTheModel: true, error: "ModelManagerError 1001")
        XCTAssertTrue(text.contains("model assets"), text)
        XCTAssertFalse(text.contains("could not be reached"), text)
        XCTAssertTrue(FMDoctor.visionLiveFailureDetail(reachedTheModel: true, error: nil)
            .contains("a live call failed"))
    }

    /// サンドボックスの中で常駐に届かなかった回だけ「確かめていない」。モデルに訊けた失敗・外で届かなかった回は ❌ のまま
    func testOnlyAnUnreachableResidentInsideASandboxIsNotChecked() {
        XCTAssertTrue(FMDoctor.notCheckedInSandbox(reachedTheModel: false, sandboxed: true))
        XCTAssertFalse(FMDoctor.notCheckedInSandbox(reachedTheModel: true, sandboxed: true))
        XCTAssertFalse(FMDoctor.notCheckedInSandbox(reachedTheModel: false, sandboxed: false))
        XCTAssertFalse(FMDoctor.notCheckedInSandbox(reachedTheModel: true, sandboxed: false))
        let detail = FMDoctor.sandboxNotCheckedDetail("On-device model")
        XCTAssertTrue(detail.hasPrefix("On-device model: not checked"), detail)
        XCTAssertFalse(detail.contains("model assets"), "確かめていない回に資産の帰属を言わない")
    }
}
