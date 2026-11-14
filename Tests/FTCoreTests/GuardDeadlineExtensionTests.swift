// 待ちのループの締め切り延長の判定(`GuardDeadlineExtension.decide`)。評価順は ①撮り直し → ②起動直後の門 → ③ガード評価の所要。
import XCTest
@testable import FTCore

final class GuardDeadlineExtensionTests: XCTestCase {

    private func decide(mayRetake: Bool = true, freshRetryArmable: Bool = false,
                        firstFrameExtended: Bool = false, firstFrameBlankObserved: Bool = false,
                        guardCostExtended: Bool = false, guardEvalCount: Int = 0,
                        hasLastOcclusion: Bool = true, stepTimeoutSeconds: Double = 5) -> GuardDeadlineExtension.Decision {
        GuardDeadlineExtension.decide(
            mayRetake: mayRetake, freshRetryArmable: freshRetryArmable,
            firstFrameExtended: firstFrameExtended, firstFrameBlankObserved: firstFrameBlankObserved,
            guardCostExtended: guardCostExtended, guardEvalCount: guardEvalCount,
            hasLastOcclusion: hasLastOcclusion, stepTimeoutSeconds: stepTimeoutSeconds)
    }

    func testNothingToExtendByDefault() {
        XCTAssertEqual(decide(), .none)
    }

    func testFreshRetakeWhenArmable() {
        XCTAssertEqual(decide(freshRetryArmable: true), .freshRetake)
        // 覆いが無くても撮り直しは延長する(失敗と決める前の確かめ)
        XCTAssertEqual(decide(freshRetryArmable: true, hasLastOcclusion: false), .freshRetake)
    }

    func testFirstFramePendingNeedsBlankObservedAndOcclusionAndNotYetExtended() {
        XCTAssertEqual(decide(firstFrameBlankObserved: true), .firstFramePending)
        XCTAssertEqual(decide(firstFrameBlankObserved: true, hasLastOcclusion: false), .none)
        XCTAssertEqual(decide(firstFrameExtended: true, firstFrameBlankObserved: true), .none)
        XCTAssertEqual(decide(firstFrameBlankObserved: false), .none)
    }

    func testGuardCostNeedsTheFirstEvaluationAndAPositiveTimeout() {
        XCTAssertEqual(decide(guardEvalCount: 1), .guardCost)
        XCTAssertEqual(decide(guardEvalCount: 2), .none)
        XCTAssertEqual(decide(guardEvalCount: 0), .none)
        XCTAssertEqual(decide(guardCostExtended: true, guardEvalCount: 1), .none)
        XCTAssertEqual(decide(guardEvalCount: 1, hasLastOcclusion: false), .none)
        XCTAssertEqual(decide(guardEvalCount: 1, stepTimeoutSeconds: 0), .none, "timeout 0 は初回1回だけの意味")
    }

    func testNothingIsExtendedWhenTheCommandBudgetIsSpent() {
        XCTAssertEqual(decide(mayRetake: false, freshRetryArmable: true, firstFrameBlankObserved: true,
                              guardEvalCount: 1), .none)
    }

    /// 順番: ① が使えれば ② ③ の条件も満たしていても ① を返す。① が使えなければ ② が ③ に先立つ
    func testOrderIsFreshRetakeThenFirstFrameThenGuardCost() {
        XCTAssertEqual(decide(freshRetryArmable: true, firstFrameBlankObserved: true, guardEvalCount: 1), .freshRetake)
        XCTAssertEqual(decide(freshRetryArmable: false, firstFrameBlankObserved: true, guardEvalCount: 1), .firstFramePending)
        XCTAssertEqual(decide(firstFrameExtended: true, firstFrameBlankObserved: true, guardEvalCount: 1), .guardCost)
    }
}
