// 直前の ref の tap が焦点を立てた欄への叩き直し(inapp F9)。実測 2026-11-01 E2EX-Flutter(in-app):
// 値入りの欄は木で `other`(入力欄と申告されない)・受け口は動かない 1x1 で、`tap(A); tap(B); type("x")` の救済が
// `FocusLanding.landed` で断られた。「動かなかった」だけで通すと容器を叩いた形が前の欄へ打つので、直前の tap が同じ id を叩いて
// その前から受け口が動いたときだけ通す。

import XCTest
@testable import FTCore

final class FocusLandingPriorTapTests: XCTestCase {

    private let receiver = CGRect(x: 16, y: 249, width: 1, height: 1)
    private let target = CGRect(x: 16, y: 248, width: 370, height: 56)

    /// 実測の形: 入力欄と申告されない・受け口は動かない 1x1 → 断られる。直前の tap の事実を足すと通る
    func testStaticReceiverOnAnUndeclaredFieldLandsOnlyWithThePriorTapFact() {
        XCTAssertFalse(FocusLanding.landed(receiver: receiver, tapped: CGPoint(x: 201, y: 276), target: target,
                                           targetIsInput: false, movedSinceTap: false, soleInnerInput: nil))
        XCTAssertTrue(FocusLanding.landed(receiver: receiver, tapped: CGPoint(x: 201, y: 276), target: target,
                                          targetIsInput: false, movedSinceTap: true, soleInnerInput: nil))
    }

    /// 実測 2026-11-01 の形: 木の包み (16,271 370x10)・救済の入れ先(中身)の枠も包みの中・受け口は箱の左上 (16,249)(木の枠の外)
    private let wrapperNow = CGRect(x: 16, y: 271, width: 370, height: 10)
    private let innerField = CGRect(x: 16, y: 271, width: 370, height: 10)

    /// 前提: 木の枠でも「動いたか」でも着地と読めない(= 実測の 409)
    func testTheMeasuredShapeIsRefusedByTheGeometryRule() {
        XCTAssertFalse(wrapperNow.contains(receiver.origin))
        XCTAssertFalse(FocusLanding.landed(receiver: receiver, tapped: CGPoint(x: 201, y: 276), target: wrapperNow,
                                           targetIsInput: false, movedSinceTap: false, soleInnerInput: nil))
    }

    func testPriorTapThatMovedTheReceiverLandsOnItsOwnTarget() {
        XCTAssertTrue(FocusLanding.priorTapLanded(receiverMovedSinceThatTap: true,
                                                  recordedTargetNow: wrapperNow, current: innerField, receiverNow: nil))
    }

    /// 容器を叩いて焦点が動かなかった(その tap の前から受け口が動いていない)形は通さない
    func testReceiverThatDidNotMoveDidNotLand() {
        XCTAssertFalse(FocusLanding.priorTapLanded(receiverMovedSinceThatTap: false,
                                                   recordedTargetNow: wrapperNow, current: innerField, receiverNow: nil))
    }

    /// 直前の tap の対象の外の要素(別の欄・外側の容器)は、その焦点のものではない
    func testElementOutsideThePriorTargetDidNotLand() {
        let otherField = CGRect(x: 16, y: 355, width: 370, height: 56)
        XCTAssertFalse(FocusLanding.priorTapLanded(receiverMovedSinceThatTap: true,
                                                   recordedTargetNow: wrapperNow, current: otherField, receiverNow: nil))
        let container = CGRect(x: 0, y: 114, width: 402, height: 678)
        XCTAssertFalse(FocusLanding.priorTapLanded(receiverMovedSinceThatTap: true,
                                                   recordedTargetNow: wrapperNow, current: container, receiverNow: nil))
    }

    /// 面積のある受け口(CMP)は、いまの受け口が叩き直す欄の上にあるときだけ着地とみなす。Enter(XCUITest 経由で in-app から
    /// 見えない)で焦点が次の欄へ移った後の clear が、移った先の欄を消した(OI-163 ①)。1x1 の受け口(Flutter)は見ない
    func testReceiverWithAreaMustStillBeOnTheField() {
        let first = CGRect(x: 16, y: 608, width: 370, height: 64)
        let second = CGRect(x: 16, y: 684, width: 370, height: 64)
        XCTAssertTrue(FocusLanding.priorTapLanded(receiverMovedSinceThatTap: true, recordedTargetNow: first,
                                                  current: first, receiverNow: first))
        XCTAssertFalse(FocusLanding.priorTapLanded(receiverMovedSinceThatTap: true, recordedTargetNow: first,
                                                   current: first, receiverNow: second), "焦点は次の欄へ移っている")
        XCTAssertTrue(FocusLanding.priorTapLanded(receiverMovedSinceThatTap: true, recordedTargetNow: wrapperNow,
                                                  current: innerField, receiverNow: receiver), "1x1 の受け口は位置で欄を指さない")
    }

    /// 焦点のタップの点: 覆われていなければ中心・中心が覆われて上側が見えていれば見えている帯の中央・丸ごと覆われていれば撃たない
    func testFocusTapPointAvoidsTheKeyboard() {
        let kb = CGRect(x: 0, y: 538, width: 402, height: 336)
        let multiline = CGRect(x: 16, y: 484, width: 370, height: 112)
        XCTAssertEqual(FocusLanding.focusTapPoint(centre: CGPoint(x: 201, y: 540), field: multiline, keyboard: kb),
                       CGPoint(x: 201, y: 511), "上側の見えている帯 484〜538 の中央")
        let first = CGRect(x: 16, y: 608, width: 370, height: 64)
        XCTAssertNil(FocusLanding.focusTapPoint(centre: CGPoint(x: 201, y: 640), field: first, keyboard: kb), "丸ごと下")
        let sliver = CGRect(x: 16, y: 532, width: 370, height: 64)
        XCTAssertNil(FocusLanding.focusTapPoint(centre: CGPoint(x: 201, y: 564), field: sliver, keyboard: kb), "帯が床未満")
        XCTAssertEqual(FocusLanding.focusTapPoint(centre: CGPoint(x: 201, y: 300), field: first, keyboard: kb),
                       CGPoint(x: 201, y: 300))
        XCTAssertEqual(FocusLanding.focusTapPoint(centre: CGPoint(x: 201, y: 640), field: first, keyboard: nil),
                       CGPoint(x: 201, y: 640))
        XCTAssertEqual(Double(FocusLanding.minimumVisibleBand), TapTargetGeometry.minimumVisibleTapExtent)
    }

    func testMissingFramesDidNotLand() {
        XCTAssertFalse(FocusLanding.priorTapLanded(receiverMovedSinceThatTap: true, recordedTargetNow: nil, current: innerField, receiverNow: nil))
        XCTAssertFalse(FocusLanding.priorTapLanded(receiverMovedSinceThatTap: true, recordedTargetNow: wrapperNow, current: nil, receiverNow: nil))
    }

    /// in-app が型を使って決める(使わない版では判定が働かない)
    func testInAppBridgeFeedsThePriorTapFactIntoTheFocusRule() throws {
        var url = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            url.deleteLastPathComponent()
        }
        let source = try String(contentsOf: url.appendingPathComponent("InAppBridge/Sources/InAppBridge.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("FocusLanding.priorTapLanded("))
        XCTAssertTrue(source.contains("if landedByPriorTap { return nil }"))
        XCTAssertEqual(source.components(separatedBy: "landedByPriorTap = self.priorTapLanded(ref: ref)").count - 1, 2,
                       "type と clear の両方が渡すこと")
    }
}
