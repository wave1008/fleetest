// シナリオの終わりに開閉を戻すのに失敗したとき、理由を言う(素の FoldControl.Failure を投げると
// 「The operation couldn’t be completed. (FTCore.FoldControl.Failure error 1.)」としか出なかった = 21周目 duo F2)

import XCTest
@testable import FTDSL
import FTCore

final class FoldRestoreMessageTests: XCTestCase {

    /// fold() と同じ文言の組み立てが、理由(状態を読めなかった・切り替わらなかった)を言う
    func testFoldFailureMessageNamesTheReason() {
        let unreadable = FoldCommandFailure(.unreadable("devicectl reports 0 active built-in displays"))
        XCTAssertTrue(unreadable.localizedDescription.contains("could not read whether the device is folded"),
                      unreadable.localizedDescription)
        XCTAssertTrue(unreadable.localizedDescription.contains("0 active built-in displays"), unreadable.localizedDescription)
    }

    /// 角度の範囲外だけが「撃つ前の引数の断り」(レーンの連続失敗に数えない)。読めない・切り替わらないは数える側
    func testOnlyOutOfRangeIsAnArgumentRejection() {
        XCTAssertEqual(StepExecutor.failureKind(thrown: FoldCommandFailure(.outOfRange(200))), .argumentRejected)
        XCTAssertNil(StepExecutor.failureKind(thrown: FoldCommandFailure(.unreadable("x"))))
        XCTAssertNil(StepExecutor.failureKind(thrown: FoldCommandFailure(.notFoldable)))
    }

    /// 配線: 戻しの経路が FoldControl.Failure を fold() と同じ文言へ写す(本物の Duo 無しでは通せない = ソース走査)
    func testRestoreMapsFoldFailuresToTheCommandMessage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FTDSL/FTRuntime.swift"), encoding: .utf8)
        guard let start = source.range(of: "public func restoreFoldIfNeeded() async throws {"),
              let end = source.range(of: "await driver.continueAfterFold()", range: start.upperBound..<source.endIndex)
        else { return XCTFail("走査の範囲が見つからない") }
        let body = String(source[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("catch let failure as FoldControl.Failure"), "戻しの失敗を素のまま投げている")
        XCTAssertTrue(body.contains("throw FoldCommandFailure(failure)"))
    }

    /// 開閉は撃つ前に「向きを変えた」と数える(数えないと `unfold()` の後の失敗に「回転はシナリオの外から来た」と付いた = 25〜26周目 duo F1)
    func testFoldCommandsCountAsReorientationBeforeSending() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FTDSL/CommandsFold.swift"), encoding: .utf8)
        guard let mark = source.range(of: "core.executor.noteDeviceReoriented()"),
              let send = source.range(of: "FoldControl.apply(target", range: mark.upperBound..<source.endIndex)
        else { return XCTFail("開閉の本体が向きの印を撃つ前に立てていない") }
        XCTAssertLessThan(mark.lowerBound, send.lowerBound)
    }
}
