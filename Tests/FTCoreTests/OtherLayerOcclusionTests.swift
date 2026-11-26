// 塗り順の無い iOS の木で「別の層に覆われているかもしれない」対象を拾う門(`otherLayerCoverSuspect`)と、
// それを使う DSL の tap の配線(`hitTest(query:)` が false のときだけ撃たずに断る)の固定。
import XCTest
@testable import FTCore

final class OtherLayerOcclusionTests: XCTestCase {
    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    private func element(_ ref: Int, _ type: String, _ id: String, _ frame: FTRect, depth: Int,
                         scrollable: Bool? = nil, z: Int? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: id, value: nil, placeholder: nil,
                    enabled: true, frame: frame, depth: depth, scrollable: scrollable, z: z)
    }

    /// 半分のシート: 背面の一覧 A の行(対象)の中心を、シートの一覧 B の行が覆う
    private func sheetTree(zTarget: Int? = nil, zOther: Int? = nil, sameList: Bool = false) -> [ElementInfo] {
        let target = element(2, "button", "row_main_07", FTRect(x: 0, y: 400, width: 402, height: 60), depth: 2,
                             z: zTarget)
        let other = element(4, "button", "queue_row_03", FTRect(x: 0, y: 380, width: 402, height: 60),
                            depth: 2, z: zOther)
        if sameList {
            return [element(1, "other", "list", FTRect(x: 0, y: 0, width: 402, height: 874), depth: 1, scrollable: true),
                    target, other]
        }
        return [element(1, "other", "list_main", FTRect(x: 0, y: 0, width: 402, height: 874), depth: 1, scrollable: true),
                target,
                element(3, "other", "list_queue", FTRect(x: 0, y: 300, width: 402, height: 574), depth: 1, scrollable: true),
                other]
    }

    private func suspect(_ tree: [ElementInfo], target ref: Int = 2) -> ElementInfo? {
        let target = tree.first { $0.ref == ref }!
        return TapTargetGeometry.otherLayerCoverSuspect(target, in: tree, screen: screen)
    }

    /// AX 当たり判定の警告(`axHitElsewhere`): 縮んだヘッダの裏のボタン(対象)の中心でナビバーのタイトルが答えた形
    private func axTree() -> [ElementInfo] {
        [element(1, "other", "root", FTRect(x: 0, y: 0, width: 402, height: 874), depth: 0),
         element(2, "staticText", "title", FTRect(x: 100, y: 50, width: 200, height: 40), depth: 1),
         element(3, "button", "follow", FTRect(x: 20, y: 40, width: 100, height: 60), depth: 1),
         element(4, "staticText", "follow_caption", FTRect(x: 30, y: 50, width: 60, height: 20), depth: 2)]
    }

    func testAxHitOnAnotherElementIsReturned() {
        let tree = axTree()
        XCTAssertEqual(TapTargetGeometry.axHitElsewhere(target: tree[2], in: tree, axHit: 2)?.identifier, "title")
    }

    func testAxHitOnTargetItsChildItsAncestorOrNothingIsSilent() {
        let tree = axTree()
        XCTAssertNil(TapTargetGeometry.axHitElsewhere(target: tree[2], in: tree, axHit: 3))
        XCTAssertNil(TapTargetGeometry.axHitElsewhere(target: tree[2], in: tree, axHit: 4))
        XCTAssertNil(TapTargetGeometry.axHitElsewhere(target: tree[2], in: tree, axHit: 1))
        XCTAssertNil(TapTargetGeometry.axHitElsewhere(target: tree[2], in: tree, axHit: nil))
        XCTAssertNil(TapTargetGeometry.axHitElsewhere(target: tree[2], in: tree, axHit: 99), "木に無い ref は名指さない")
    }

    /// 問い合わせの門: 対象の中心に祖先・子孫でない別の要素が重なるタップだけ聞く(普通のタップに往復を足さない)
    func testAxHitIsAskedOnlyWhenAnotherElementOverlapsTheCentre() {
        let tree = axTree()
        var overlapping = tree
        overlapping[1] = element(2, "staticText", "title", FTRect(x: 56, y: 60, width: 226, height: 28), depth: 1)
        XCTAssertTrue(TapTargetGeometry.centreOverlappedOutsideLineage(tree[2], in: overlapping), "中心 (70,70) にタイトルの枠が重なる")
        XCTAssertFalse(TapTargetGeometry.centreOverlappedOutsideLineage(tree[2], in: tree), "タイトルが中心から外れていれば聞かない")
        let alone = [tree[0], tree[2], tree[3]]
        XCTAssertFalse(TapTargetGeometry.centreOverlappedOutsideLineage(tree[2], in: alone), "根(祖先)と自分の文字(子孫)だけなら聞かない")
    }

    func testSheetShapeNamesTheOtherLayersRow() {
        XCTAssertEqual(suspect(sheetTree())?.identifier, "queue_row_03")
    }

    func testOverlapInsideTheSameScrollContainerIsNotSuspected() {
        XCTAssertNil(suspect(sheetTree(sameList: true)))
    }

    func testAnyPaintOrderInTheTreeClosesTheGate() {
        XCTAssertNil(suspect(sheetTree(zTarget: 1, zOther: 2)))
        XCTAssertNil(suspect(sheetTree(zOther: 2)), "片方にだけ z があっても全か無かでない木は対象外")
    }

    func testLineageIsNotSuspected() {
        // 対象の祖先(行を包む別の押せる要素)・子孫は覆いではない
        let parent = element(1, "button", "card", FTRect(x: 0, y: 380, width: 402, height: 200), depth: 1, scrollable: nil)
        let target = element(2, "button", "inner", FTRect(x: 20, y: 400, width: 100, height: 60), depth: 2)
        let child = element(3, "button", "inner_child", FTRect(x: 30, y: 410, width: 50, height: 40), depth: 3)
        let tree = [parent, target, child]
        XCTAssertNil(TapTargetGeometry.otherLayerCoverSuspect(target, in: tree, screen: screen))
    }

    func testAnOtherThatWrapsTheTargetWholeIsNotSuspected() {
        // 別の容器の中の大きな押せる要素が対象を丸ごと包む(ラッパー)= 覆いではない
        let target = element(2, "button", "row", FTRect(x: 10, y: 400, width: 100, height: 40), depth: 2)
        let wrapper = element(4, "button", "wrapper", FTRect(x: 0, y: 300, width: 402, height: 300), depth: 2)
        let tree = [element(1, "other", "a", FTRect(x: 0, y: 0, width: 402, height: 874), depth: 1, scrollable: true),
                    target,
                    element(3, "other", "b", FTRect(x: 0, y: 200, width: 402, height: 600), depth: 1, scrollable: true),
                    wrapper]
        XCTAssertNil(TapTargetGeometry.otherLayerCoverSuspect(target, in: tree, screen: screen))
    }

    func testAnOtherWhollyInsideTheTargetIsNotSuspected() {
        let target = element(2, "button", "big", FTRect(x: 0, y: 300, width: 402, height: 300), depth: 2)
        let small = element(4, "button", "small", FTRect(x: 100, y: 400, width: 50, height: 50), depth: 2)
        let tree = [element(1, "other", "a", FTRect(x: 0, y: 0, width: 402, height: 874), depth: 1, scrollable: true),
                    target,
                    element(3, "other", "b", FTRect(x: 0, y: 200, width: 402, height: 600), depth: 1, scrollable: true),
                    small]
        XCTAssertNil(TapTargetGeometry.otherLayerCoverSuspect(target, in: tree, screen: screen))
    }

    func testNonOperableOtherIsNotSuspected() {
        var tree = sheetTree()
        tree[3].type = "staticText"
        XCTAssertNil(suspect(tree))
    }

    func testCentreOutsideTheScreenClosesTheGate() {
        var tree = sheetTree()
        tree[1].frame = FTRect(x: 0, y: 900, width: 402, height: 60)
        XCTAssertNil(suspect(tree))
    }

    func testOneSideWithoutAScrollContainerCountsAsAnotherLayer() {
        // 対象が容器の外(固定のバー)・相手が容器の中の行: 容器が違う
        var tree = sheetTree()
        tree.removeAll { $0.ref == 1 }
        XCTAssertEqual(suspect(tree)?.identifier, "queue_row_03")
    }

    func testCandidatesAreEveryOtherLayerOverlapInTreeOrder() {
        var tree = sheetTree()
        tree.append(element(6, "button", "queue_row_04", FTRect(x: 0, y: 410, width: 402, height: 60), depth: 2))
        let target = tree.first { $0.ref == 2 }!
        let all = TapTargetGeometry.otherLayerCoverCandidates(target, in: tree, screen: screen).map(\.ref)
        XCTAssertEqual(all, [4, 6])
        XCTAssertEqual(suspect(tree)?.ref, 4, "suspect は候補の先頭")
        XCTAssertTrue(TapTargetGeometry.otherLayerCoverCandidates(target, in: sheetTree(sameList: true), screen: screen).isEmpty)
    }

    /// 撃ってよいのは「全部引けて・対象に届き・覆いのどれにも届かない」ときだけ(両方向)
    func testTouchClearsCoversOnlyWhenTheTouchReachesTheTargetAndNoCover() {
        func lands(_ refs: [Int], unresolved: [Int] = []) -> TouchLandsResponse {
            TouchLandsResponse(receiver: "HostingView", lands: refs, unresolved: unresolved)
        }
        XCTAssertTrue(TapTargetGeometry.touchClearsCovers(lands([2]), target: 2, covers: [4, 6]))
        XCTAssertFalse(TapTargetGeometry.touchClearsCovers(lands([2, 6]), target: 2, covers: [4, 6]), "覆いの1つに届く")
        XCTAssertFalse(TapTargetGeometry.touchClearsCovers(lands([4]), target: 2, covers: [4]), "対象に届かない")
        XCTAssertFalse(TapTargetGeometry.touchClearsCovers(lands([]), target: 2, covers: [4]), "何にも届かない(別の窓など)")
        XCTAssertFalse(TapTargetGeometry.touchClearsCovers(lands([2], unresolved: [4]), target: 2, covers: [4]), "引けない覆い")
        XCTAssertFalse(TapTargetGeometry.touchClearsCovers(nil, target: 2, covers: [4]), "答えられない(xcuitest モード)")
        XCTAssertFalse(TapTargetGeometry.touchClearsCovers(lands([2]), target: 2, covers: []), "覆いの候補が無い")
        // 自前描画(全要素が同じ view)= 覆いにも届く
        XCTAssertFalse(TapTargetGeometry.touchClearsCovers(lands([2, 4]), target: 2, covers: [4]))
    }

    /// true を覆す材料は「全部引けて・対象に届かず・覆いのどれかに届く」だけ(両方向)
    func testTouchLandsOnCoverInsteadOnlyOnPositiveEvidence() {
        func lands(_ refs: [Int], unresolved: [Int] = []) -> TouchLandsResponse {
            TouchLandsResponse(receiver: "HostingView", lands: refs, unresolved: unresolved)
        }
        let cover = ElementInfo(ref: 4, type: "button", identifier: "queue_row_03", label: "キュー 03", value: nil, placeholder: nil,
                                enabled: true, frame: FTRect(x: 0, y: 380, width: 402, height: 60), depth: 2)
        XCTAssertEqual(TapTargetGeometry.touchLandsOnCoverInstead(lands([4]), target: 2, covers: [cover])?.ref, 4)
        XCTAssertNil(TapTargetGeometry.touchLandsOnCoverInstead(lands([2, 4]), target: 2, covers: [cover]), "対象にも届く(自前描画)")
        XCTAssertNil(TapTargetGeometry.touchLandsOnCoverInstead(lands([]), target: 2, covers: [cover]), "どれにも届かない")
        XCTAssertNil(TapTargetGeometry.touchLandsOnCoverInstead(lands([4], unresolved: [2]), target: 2, covers: [cover]), "引けない ref")
        XCTAssertNil(TapTargetGeometry.touchLandsOnCoverInstead(nil, target: 2, covers: [cover]), "答えられない")
    }
}

/// DSL の tap: 門が開く木で `hitTest(query:)` が false のときだけ撃たずに断る
final class OtherLayerHitTestWiringTests: XCTestCase {
    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    private func element(_ ref: Int, _ type: String, _ id: String, _ label: String, _ frame: FTRect, depth: Int,
                         scrollable: Bool? = nil, z: Int? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil, placeholder: nil,
                    enabled: true, frame: frame, depth: depth, scrollable: scrollable, z: z)
    }

    private func sheetTree() -> [ElementInfo] {
        [element(1, "other", "list_main", "list_main", FTRect(x: 0, y: 0, width: 402, height: 874), depth: 1, scrollable: true),
         element(2, "button", "row_main_07", "本文 07", FTRect(x: 0, y: 400, width: 402, height: 60), depth: 2),
         element(3, "other", "list_queue", "list_queue", FTRect(x: 0, y: 300, width: 402, height: 574), depth: 1, scrollable: true),
         element(4, "button", "queue_row_03", "キュー 03", FTRect(x: 0, y: 380, width: 402, height: 60), depth: 2)]
    }

    private func closedGateTree() -> [ElementInfo] {
        // 同じ容器の中の重なり = 門は閉じる
        [element(1, "other", "list", "list", FTRect(x: 0, y: 0, width: 402, height: 874), depth: 1, scrollable: true),
         element(2, "button", "row_main_07", "本文 07", FTRect(x: 0, y: 400, width: 402, height: 60), depth: 2),
         element(4, "button", "queue_row_03", "キュー 03", FTRect(x: 0, y: 380, width: 402, height: 60), depth: 2)]
    }

    private func run(_ tree: [ElementInfo], answer: HitTestAnswer, android: Bool = false)
        async -> (FakeQueryDriver, StepOutcome) {
        let driver = FakeQueryDriver(elements: tree, screen: screen, answer: answer)
        let outcome = await StepExecutor(driver: driver, isAndroid: android, tunables: RunTunables())
            .execute(FlowStep(action: "tap", locator: FlowLocator(label: "本文 07")))
        return (driver, outcome)
    }

    func testFalseRefusesWithoutTouching() async {
        let (driver, outcome) = await run(sheetTree(), answer: .hittable(false))
        XCTAssertTrue(driver.taps.isEmpty, "撃った: \(driver.taps)")
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(message.contains("cannot be hit"), message)
        XCTAssertTrue(message.contains("queue_row_03"), "覆いを名指しすること: \(message)")
        XCTAssertEqual(driver.queries.count, 1)
        XCTAssertEqual(driver.queries.first?.identifier, "row_main_07")
    }

    func testTrueAndUnavailableAndUnresolvableStillFire() async {
        for answer in [HitTestAnswer.hittable(true), .unavailable, .unresolvable] {
            let (driver, outcome) = await run(sheetTree(), answer: answer)
            XCTAssertFalse(driver.taps.isEmpty, "\(answer): 撃たれなかった \(outcome.status)")
            XCTAssertEqual(driver.queries.count, 1, "\(answer)")
        }
    }

    func testClosedGateNeverAsks() async {
        let (driver, _) = await run(closedGateTree(), answer: .hittable(false))
        XCTAssertTrue(driver.queries.isEmpty, "門が閉じているのに照会した")
    }

    /// false でも、in-app の当たり判定が「対象だけに届く」と答えたら撃ち、注記を残す(送って戻した SwiftUI の FAB の形)
    func testFalseButTouchReachingOnlyTheTargetFiresWithANote() async {
        let driver = FakeQueryDriver(elements: sheetTree(), screen: screen, answer: .hittable(false),
                                     lands: TouchLandsResponse(receiver: "HostingView", lands: [2], unresolved: []))
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .execute(FlowStep(action: "tap", locator: FlowLocator(label: "本文 07")))
        XCTAssertEqual(driver.landsAsked, [[2, 4]], "対象と覆いの候補を聞くこと")
        XCTAssertEqual(driver.taps.count, 1, "撃たなかった: \(outcome.status)")
        XCTAssertTrue(outcome.notes.contains(.touchReachesTargetDespiteHitTest), "\(outcome.notes)")
    }

    /// false で、当たり判定が覆いにも届くと答えたら断る(自前描画・本当に覆われている形)
    func testFalseAndTouchReachingACoverRefuses() async {
        let driver = FakeQueryDriver(elements: sheetTree(), screen: screen, answer: .hittable(false),
                                     lands: TouchLandsResponse(receiver: "FlutterView", lands: [2, 4], unresolved: []))
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .execute(FlowStep(action: "tap", locator: FlowLocator(label: "本文 07")))
        XCTAssertTrue(driver.taps.isEmpty, "撃った: \(driver.taps)")
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(message.contains("cannot be hit"), message)
        XCTAssertFalse(outcome.notes.contains(.touchReachesTargetDespiteHitTest))
    }

    /// true も誤ることがある(SwiftUI の半分のシートの裏の行): 当たり判定が「対象に届かず覆いに届く」と言い切ったときだけ断る
    func testTrueButTouchLandingOnlyOnACoverRefuses() async {
        let driver = FakeQueryDriver(elements: sheetTree(), screen: screen, answer: .hittable(true),
                                     lands: TouchLandsResponse(receiver: "HostingView", lands: [4], unresolved: []))
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .execute(FlowStep(action: "tap", locator: FlowLocator(label: "本文 07")))
        XCTAssertEqual(driver.landsAsked, [[2, 4]])
        XCTAssertTrue(driver.taps.isEmpty, "撃った: \(driver.taps)")
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(message.contains("lands on"), message)
        XCTAssertTrue(message.contains("queue_row_03"), "届いた覆いを名指すこと: \(message)")
    }

    /// true で、対象にも届く(自前描画 = 全要素が同じ view)・答えられない・引けない ref がある、は従来どおり撃つ
    func testTrueFiresUnlessTheTouchProvablyMissesTheTarget() async {
        let answers: [TouchLandsResponse?] = [
            TouchLandsResponse(receiver: "FlutterView", lands: [2, 4], unresolved: []),
            TouchLandsResponse(receiver: "HostingView", lands: [2], unresolved: []),
            TouchLandsResponse(receiver: "HostingView", lands: [4], unresolved: [2]),
            TouchLandsResponse(receiver: nil, lands: [], unresolved: []),
            nil,
        ]
        for lands in answers {
            let driver = FakeQueryDriver(elements: sheetTree(), screen: screen, answer: .hittable(true), lands: lands)
            let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
                .execute(FlowStep(action: "tap", locator: FlowLocator(label: "本文 07")))
            XCTAssertEqual(driver.taps.count, 1, "\(String(describing: lands)): 撃たれなかった \(outcome.status)")
        }
    }

    /// 隠れたバーのボタンの中心に、一覧の上端の外へ出た(送り残しと読まれる)行が重なる形
    private func hiddenBarTree(rowOverlapsCentre: Bool = true) -> [ElementInfo] {
        [element(1, "other", "bar_top", "bar_top", FTRect(x: 0, y: 0, width: 402, height: 163), depth: 1),
         element(2, "button", "btn_top_action", "上アクション", FTRect(x: 322, y: 127, width: 64, height: 20), depth: 2),
         element(3, "other", "list", "list", FTRect(x: 0, y: 163, width: 402, height: 711), depth: 1, scrollable: true),
         element(4, "button", "row_h_12", "行 12",
                 FTRect(x: 0, y: rowOverlapsCentre ? 108 : 60, width: 402, height: 48), depth: 2)]
            + (0..<5).map { i in
                element(5 + i, "button", "row_h_\(13 + i)", "行 \(13 + i)",
                        FTRect(x: 0, y: 163 + Double(i) * 48, width: 402, height: 48), depth: 2)
            }
    }

    private func runHidden(_ tree: [ElementInfo], answer: HitTestAnswer, lands: TouchLandsResponse? = nil)
        async -> (FakeQueryDriver, StepOutcome) {
        let driver = FakeQueryDriver(elements: tree, screen: screen, answer: answer, lands: lands)
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .execute(FlowStep(action: "tap", locator: FlowLocator(label: "上アクション")))
        return (driver, outcome)
    }

    func testOutsideWindowRowOverTheCentreIsNotACandidateButIsProbed() {
        let tree = hiddenBarTree()
        XCTAssertTrue(TapTargetGeometry.otherLayerCoverCandidates(tree[1], in: tree, screen: screen).isEmpty, "前提: 送り残しは候補から外れる")
        XCTAssertEqual(TapTargetGeometry.outsideWindowOverlapProbe(tree[1], in: tree, screen: screen)?.identifier, "row_h_12")
    }

    func testOutsideWindowRowNotOverTheCentreIsNotProbed() {
        let tree = hiddenBarTree(rowOverlapsCentre: false)
        XCTAssertNil(TapTargetGeometry.outsideWindowOverlapProbe(tree[1], in: tree, screen: screen))
    }

    /// 送り残しの行が中心に重なり false → 撃たずに断る(名指さない)
    func testOutsideWindowRowAndFalseRefusesWithoutNaming() async {
        let (driver, outcome) = await runHidden(hiddenBarTree(), answer: .hittable(false))
        XCTAssertTrue(driver.taps.isEmpty, "撃った: \(driver.taps)")
        XCTAssertEqual(driver.queries.count, 1)
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(message.contains("cannot be hit"), message)
        XCTAssertFalse(message.contains("row_h_12") || message.contains("行 12"), "手前だと名指さない: \(message)")
    }

    /// 同じ形で true・答えられない・引き当て不能は撃つ(1回だけ聞く)
    func testOutsideWindowRowAndNonFalseAnswersFire() async {
        for answer in [HitTestAnswer.hittable(true), .unavailable, .unresolvable] {
            let (driver, outcome) = await runHidden(hiddenBarTree(), answer: answer)
            XCTAssertEqual(driver.taps.count, 1, "\(answer): 撃たれなかった \(outcome.status)")
            XCTAssertEqual(driver.queries.count, 1, "\(answer)")
        }
    }

    /// 重ならない形では照会しない
    func testOutsideWindowRowNotOverTheCentreNeverAsks() async {
        let (driver, _) = await runHidden(hiddenBarTree(rowOverlapsCentre: false), answer: .hittable(false))
        XCTAssertTrue(driver.queries.isEmpty, "\(driver.queries)")
        XCTAssertEqual(driver.taps.count, 1)
    }

    /// inapp-boost: false でも本物のタッチが対象だけに届くなら撃つ(既存の false の扱いと同じ)
    func testOutsideWindowRowAndFalseButTouchReachingOnlyTheTargetFires() async {
        let (driver, outcome) = await runHidden(
            hiddenBarTree(), answer: .hittable(false),
            lands: TouchLandsResponse(receiver: "HostingView", lands: [2], unresolved: []))
        XCTAssertEqual(driver.landsAsked, [[2, 4]])
        XCTAssertEqual(driver.taps.count, 1, "\(outcome.status)")
        XCTAssertTrue(outcome.notes.contains(.touchReachesTargetDespiteHitTest))
    }

    /// 中心だけ別の層の帯(タブ)に覆われ、上に見えている部分が残る行
    private func rowUnderTabTree(z: Bool) -> [ElementInfo] {
        [element(1, "other", "list_main", "list_main", FTRect(x: 0, y: 0, width: 402, height: 874), depth: 1, scrollable: true, z: z ? 0 : nil),
         element(2, "button", "row_main_07", "本文 07", FTRect(x: 0, y: 760, width: 402, height: 100), depth: 2, z: z ? 1 : nil),
         element(3, "button", "tab_home", "ホーム", FTRect(x: 0, y: 790, width: 402, height: 84), depth: 1, z: z ? 2 : nil)]
    }

    /// 塗り順のある木(全要素に z。`PaintOrder.isReal`): 見えている部分を押し、別の層の照会は門が閉じて撃たない
    /// (照会が false を返しても断らない = 押せる行を断る誤った赤にしない)
    func testVisiblePartWinsOverTheQuery() async {
        let tree = rowUnderTabTree(z: true)
        XCTAssertNil(TapTargetGeometry.otherLayerCoverSuspect(tree[1], in: tree, screen: screen), "前提: 塗り順のある木は門が閉じる")
        let (driver, outcome) = await run(tree, answer: .hittable(false))
        XCTAssertTrue(driver.queries.isEmpty, "見えている部分を押せる形で照会した: \(driver.queries)")
        XCTAssertEqual(driver.taps.count, 1, "見えている部分を撃つこと: \(driver.taps) \(outcome.status)")
        XCTAssertTrue(driver.taps.first?.hasPrefix("xy:") == true, "\(driver.taps)")
    }

    /// 塗り順の無い木(z 無し)では見えている部分を選ばず、門が開いて照会し、false なら撃たずに断る
    func testWithoutPaintOrderTheQueryDecidesAndFalseRefuses() async {
        let tree = rowUnderTabTree(z: false)
        XCTAssertNotNil(TapTargetGeometry.otherLayerCoverSuspect(tree[1], in: tree, screen: screen), "前提: 門は開く形")
        let (driver, outcome) = await run(tree, answer: .hittable(false))
        XCTAssertEqual(driver.queries.count, 1)
        XCTAssertTrue(driver.taps.isEmpty, "撃った: \(driver.taps)")
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(message.contains("cannot be hit"), message)
    }

    /// シートが木の前に並ぶ形(SwiftUI のように覆いが対象より前の ref)= 木の順の注記(may have hit)は出ない形。結果の文字を1つ持つ
    private func coverFirstTree() -> [ElementInfo] {
        [element(1, "other", "list_queue", "list_queue", FTRect(x: 0, y: 300, width: 402, height: 574), depth: 1, scrollable: true),
         element(2, "button", "queue_row_03", "キュー 03", FTRect(x: 0, y: 380, width: 402, height: 60), depth: 2),
         element(3, "other", "list_main", "list_main", FTRect(x: 0, y: 0, width: 402, height: 874), depth: 1, scrollable: true),
         element(4, "button", "row_main_07", "本文 07", FTRect(x: 0, y: 400, width: 402, height: 60), depth: 2),
         element(5, "staticText", "txt_result", "player=none", FTRect(x: 16, y: 100, width: 200, height: 24), depth: 1)]
    }

    /// tap の後に結果を確かめて赤にする(実際に効かなかった = 失敗で分かる)
    private func tapThenFailingCheck(_ tree: [ElementInfo], answer: HitTestAnswer) async -> (tap: StepOutcome, check: StepOutcome) {
        let driver = FakeQueryDriver(elements: tree, screen: screen, answer: answer)
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
        let tap = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(label: "本文 07")))
        let check = await executor.execute(FlowStep(assert: "textEquals", locator: FlowLocator(id: "txt_result"),
                                                    expected: "player=main:row_main_07", timeout: 0, occlusionGuard: false))
        return (tap, check)
    }

    /// **緑の手では黙り、後続が赤になったときだけ**、直前の tap が重なりの疑いのまま撃たれたことを名指して直し方を言う
    /// (true・答えなし・引き当て不能のどれでも = 照会で断れなかった形)
    func testFailureAfterAnUnconfirmedOtherLayerCoverNamesItAndSaysHowToFix() async {
        for answer in [HitTestAnswer.hittable(true), .unavailable, .unresolvable] {
            let (tap, check) = await tapThenFailingCheck(coverFirstTree(), answer: answer)
            guard case .passed = tap.status else { return XCTFail("\(answer): tap は撃つ \(tap.status)") }
            XCTAssertFalse((tap.driverFallback ?? "").contains("fix the scenario"), "\(answer): 緑の手で言った \(tap.driverFallback ?? "")")
            guard case .failed(let message) = check.status else { return XCTFail("\(answer): \(check.status)") }
            XCTAssertTrue(message.contains("queue_row_03") && message.contains("fix the scenario"), "\(answer): \(message)")
            XCTAssertTrue(check.notes.contains(.coveredTouchBeforeFailure), "\(answer): \(check.notes)")
        }
    }

    /// 木の順の覆い(may have hit)の形も同じく、赤になったときに直し方を言う
    func testFailureAfterATreeOrderCoverAlsoSaysHowToFix() async {
        var tree = sheetTree()
        tree.append(element(5, "staticText", "txt_result", "player=none", FTRect(x: 16, y: 100, width: 200, height: 24), depth: 1))
        let (_, check) = await tapThenFailingCheck(tree, answer: .hittable(true))
        guard case .failed(let message) = check.status else { return XCTFail("\(check.status)") }
        XCTAssertTrue(message.contains("fix the scenario"), message)
    }

    /// 容器の上端に貼り付いた見出しの下の行(塗り順の無い木 = 送り出さずに中心を撃つ)も、赤になったときに見出しを名指す。
    /// 形は 11/11 の xcuitest の赤の木: RN は見出しが全幅で木に出る・Flutter は見出しの文字の枠だけ(帯は推定)
    func testFailureAfterATapUnderAStickyHeaderNamesTheHeader() async {
        let rn = [element(1, "other", "scroll", "scroll", FTRect(x: 16, y: 157, width: 370, height: 700), depth: 1, scrollable: true),
                  element(2, "staticText", "hdr_B", "セクション B", FTRect(x: 16, y: 156, width: 370, height: 33), depth: 2),
                  element(3, "button", "row_s_B1", "本文 07", FTRect(x: 32, y: 161, width: 338, height: 44), depth: 2),
                  element(4, "button", "row_s_B2", "行 B2", FTRect(x: 32, y: 209, width: 338, height: 44), depth: 2),
                  element(5, "staticText", "txt_result", "player=none", FTRect(x: 16, y: 100, width: 200, height: 24), depth: 1)]
        let flutter = [element(1, "staticText", "hdr_F", "セクション F", FTRect(x: 16, y: 180, width: 83, height: 20), depth: 1),
                       element(2, "other", "scroll", "scroll", FTRect(x: 0, y: 170, width: 402, height: 704), depth: 1, scrollable: true),
                       element(3, "button", "row_s_F3", "本文 07", FTRect(x: 0, y: 170, width: 402, height: 45), depth: 2),
                       element(4, "button", "row_s_F4", "行 F4", FTRect(x: 0, y: 215, width: 402, height: 56), depth: 2),
                       element(5, "staticText", "txt_result", "player=none", FTRect(x: 16, y: 100, width: 200, height: 24), depth: 1)]
        for (name, tree, header) in [("RN", rn, "hdr_B"), ("Flutter", flutter, "hdr_F")] {
            let (tap, check) = await tapThenFailingCheck(tree, answer: .unavailable)
            guard case .passed = tap.status else { return XCTFail("\(name): tap は撃つ \(tap.status)") }
            guard case .failed(let message) = check.status else { return XCTFail("\(name): \(check.status)") }
            XCTAssertTrue(message.contains(header) && message.contains("fix the scenario"), "\(name): \(message)")
            XCTAssertTrue(check.notes.contains(.coveredTouchBeforeFailure), "\(name): \(check.notes)")
        }
    }

    /// 重なりの疑いが無い tap の後の赤には言わない
    func testFailureWithoutOverlapSaysNothingAboutCovering() async {
        let tree = [element(1, "other", "list_main", "list_main", FTRect(x: 0, y: 0, width: 402, height: 874), depth: 1, scrollable: true),
                    element(2, "button", "row_main_07", "本文 07", FTRect(x: 0, y: 400, width: 402, height: 60), depth: 2),
                    element(5, "staticText", "txt_result", "player=none", FTRect(x: 16, y: 100, width: 200, height: 24), depth: 1)]
        let (_, check) = await tapThenFailingCheck(tree, answer: .unavailable)
        guard case .failed(let message) = check.status else { return XCTFail("\(check.status)") }
        XCTAssertFalse(message.contains("fix the scenario"), message)
        XCTAssertFalse(check.notes.contains(.coveredTouchBeforeFailure), "\(check.notes)")
    }

    func testAndroidNeverAsks() async {
        let (driver, _) = await run(sheetTree(), answer: .hittable(false), android: true)
        XCTAssertTrue(driver.queries.isEmpty, "Android で照会した")
    }
}

private final class FakeQueryDriver: AppDriver, @unchecked Sendable {
    let elements: [ElementInfo]
    let screen: FTRect
    let answer: HitTestAnswer
    let lands: TouchLandsResponse?
    private(set) var taps: [String] = []
    private(set) var queries: [HitTestQuery] = []
    private(set) var landsAsked: [[Int]] = []

    init(elements: [ElementInfo], screen: FTRect, answer: HitTestAnswer, lands: TouchLandsResponse? = nil) {
        self.elements = elements
        self.screen = screen
        self.answer = answer
        self.lands = lands
    }

    func hitTest(query: HitTestQuery) async -> HitTestAnswer {
        queries.append(query)
        return answer
    }

    func touchLands(x: Double, y: Double, refs: [Int]) async -> TouchLandsResponse? {
        landsAsked.append(refs)
        return lands
    }

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws -> String? { nil }
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func terminate() async throws {}
    func screenshot() async throws -> Data { Data() }
    func type(ref: Int?, text: String) async throws {}
    func tap(ref: Int) async throws { taps.append("ref:\(ref)") }
    func tap(x: Double, y: Double) async throws { taps.append("xy:\(x),\(y)") }
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements, truncatedCount: 0)
    }
}
