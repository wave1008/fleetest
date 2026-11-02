// **入口 × 操作 × 検査の表**(撃つ前の守りを入口ごとに手で配線しているので、漏れを表の空きとして見せる)。
// 入口 = DSL(StepExecutor)・MCP(ft_*)・CLI(ManualDriveCommands)・ライブ操作(api live serve)。
// 検査は漏れが出た6つに絞る(swipe・gesture・アラートは対象外。アラートは DSL の SystemUIGate・XCUITest のランナーが全入口で断る)。
// 各マスは 振る舞いのテスト / 走査のテスト / 純粋関数だけのテスト / 対象外(理由)/ 未対応(確かめるテストが無い)のどれか。
// - 入口に操作があり検査が当てはまるマスが表に無ければ落ちる(新しい入口・操作を足したらここで決める)
// - 名指したテストが実在しなければ落ちる(改名・削除で表が嘘になる)
// - 未対応の数を等号で固定する(増やすには理由を書いて数を上げる。直したら数を下げる)
// 振る舞いのテストは偽ドライバが本物と同じ答え方をする前提(`DriverAnswers`)。走査は配線の有無だけを見る弱い縛り。

import XCTest

final class FireRoutesTableTests: XCTestCase {

    enum Entrance: String, CaseIterable { case dsl, mcp, cli, live }

    enum Op: String, CaseIterable {
        case tapRef, longPressRef, typeRef, clearRef, dragRef, doubleTapRef, pinchRef
        case tapCoord, longPressCoord, doubleTapCoord, dragCoord, pinchCoord
        case typeRefLess, clearRefLess, pressEnter

        var isRef: Bool { [.tapRef, .longPressRef, .typeRef, .clearRef, .dragRef, .doubleTapRef, .pinchRef].contains(self) }
        var isCoord: Bool { [.tapCoord, .longPressCoord, .doubleTapCoord, .dragCoord, .pinchCoord].contains(self) }
    }

    enum Check: String, CaseIterable { case refIdentity, keyboard, onScreen, frontApp, covering, bottomBand }

    enum Cell {
        case behavior([String])
        case scan([String])
        case pure([String])
        case exempt(String)
        case pending(String)
    }

    /// DSL の ref 形はロケータ(撃つ直前に解決する)と読み替える
    static let ops: [Entrance: [Op]] = [
        .dsl: [.tapRef, .longPressRef, .typeRef, .clearRef, .dragRef, .doubleTapRef, .pinchRef,
               .tapCoord, .longPressCoord, .doubleTapCoord, .dragCoord, .typeRefLess, .clearRefLess, .pressEnter],
        .mcp: Op.allCases,
        .cli: [.tapRef, .longPressRef, .typeRef, .tapCoord, .typeRefLess],
        .live: [.tapRef, .typeRef, .clearRef, .doubleTapRef, .pinchRef,
                .tapCoord, .longPressCoord, .doubleTapCoord, .dragCoord, .typeRefLess, .clearRefLess],
    ]

    static func applies(_ check: Check, to op: Op) -> Bool {
        switch check {
        case .refIdentity: return op.isRef
        case .keyboard, .covering: return op.isRef || op.isCoord
        case .onScreen: return op.isCoord
        case .frontApp: return true
        case .bottomBand: return [.tapRef, .longPressRef, .doubleTapRef].contains(op)
        }
    }

    // MARK: - 対象外の理由(同じ理由を何度も書かない)

    static let dslLocatorAtFire = "ロケータは撃つ直前に解決し、その木の座標・ref で撃つ(人が見た ref の番号を跨がない)"
    static let dslCoveringCost = "覆いの照会は1手ごとの往復 = DSL は1 run で数千回撃つ(MCPServer.systemUICoveringWarning の費用の doc)"
    static let dslLocatorInApp = "ロケータは起こしたアプリの木で解決する(Android の木は前面の窓 = 別のアプリなら見つからず赤)"
    static let dslCoordIntent = "座標は書き手が意図して書く(キーを押す・別の面を押す意図もある)ので DSL では検査しない(D2 の決定)"
    static let cliNoSession = "CLI は1回ごとに独立したコマンドで、前面にあるべきアプリを知る口が無い"
    static let runnerRefusesBackground = "iOS は XCUITest のランナーが前面でないアプリへの操作を 422 で断る・Android は木が前面の窓"
    static let liveFollows = "ライブ操作は撃つ前に followFrontmost が前面(覆い・アラートを含む)へ追従する = 人が見ている面へ撃つ設計"
    static let liveHumanCoord = "ライブ操作の座標は人が画面を見て押す(キーを押す意図もある)"

    static let table: [Entrance: [Op: [Check: Cell]]] = [
        .dsl: [
            .tapRef: [.refIdentity: .behavior(["RefExpectationScopeWiringTests.testTapCarriesTheResolvedElement"]),
                      .keyboard: .behavior(["StepExecutorTests.testTapTypeAndClearInputUnderTheKeyboardCloseItFirst"]),
                      .covering: .exempt(dslCoveringCost), .frontApp: .exempt(dslLocatorInApp),
                      .bottomBand: .behavior(["BottomGestureBandTests.testTapOnAnElementWhoseCentreIsInTheBandTouchesItsPartAboveTheBand"])],
            .longPressRef: [.refIdentity: .behavior(["RefExpectationScopeWiringTests.testLongPressCarriesTheResolvedElement"]),
                            .keyboard: .scan(["PreFireGuardTests.testEntranceIsCalledOnceBeforeTheActionSwitch"]),
                            .covering: .exempt(dslCoveringCost), .frontApp: .exempt(dslLocatorInApp),
                            .bottomBand: .behavior(["BottomGestureBandTests.testLongPressAndDoubleTapInTheBandTouchAboveIt"])],
            .typeRef: [.refIdentity: .behavior(["RefExpectationScopeWiringTests.testTypeCarriesTheResolvedElement"]),
                       .keyboard: .behavior(["StepExecutorTests.testTapTypeAndClearInputUnderTheKeyboardCloseItFirst"]),
                       .covering: .exempt(dslCoveringCost), .frontApp: .exempt(dslLocatorInApp)],
            .clearRef: [.refIdentity: .behavior(["RefExpectationScopeWiringTests.testClearCarriesTheResolvedElement"]),
                        .keyboard: .behavior(["StepExecutorTests.testTapTypeAndClearInputUnderTheKeyboardCloseItFirst"]),
                        .covering: .exempt(dslCoveringCost), .frontApp: .exempt(dslLocatorInApp)],
            .dragRef: [.refIdentity: .exempt(dslLocatorAtFire),
                       .keyboard: .scan(["PreFireGuardTests.testEntranceIsCalledOnceBeforeTheActionSwitch"]),
                       .covering: .exempt(dslCoveringCost), .frontApp: .exempt(dslLocatorInApp)],
            .doubleTapRef: [.refIdentity: .exempt(dslLocatorAtFire),
                            .keyboard: .behavior(["KeyboardClosedTargetLostTests.testDoubleTapAlsoFailsWithoutTouching"]),
                            .covering: .exempt(dslCoveringCost), .frontApp: .exempt(dslLocatorInApp),
                            .bottomBand: .behavior(["BottomGestureBandTests.testLongPressAndDoubleTapInTheBandTouchAboveIt"])],
            .pinchRef: [.refIdentity: .exempt(dslLocatorAtFire),
                        .keyboard: .scan(["PreFireGuardTests.testEntranceIsCalledOnceBeforeTheActionSwitch"]),
                        .covering: .exempt(dslCoveringCost), .frontApp: .exempt(dslLocatorInApp)],
            .tapCoord: [.onScreen: .behavior(["CoordinateTapRoutingTests.testNegativePointIsRefusedWithoutReadingTheTree",
                                              "CoordinateTapRoutingTests.testPointBeyondTheScreenIsRefusedWhenTheTreeIsRead"]),
                        .keyboard: .exempt(dslCoordIntent), .frontApp: .exempt(dslCoordIntent), .covering: .exempt(dslCoveringCost)],
            .longPressCoord: [.onScreen: .behavior(["CoordinateTapRoutingTests.testNegativePointIsRefusedWithoutReadingTheTree"]),
                              .keyboard: .exempt(dslCoordIntent), .frontApp: .exempt(dslCoordIntent), .covering: .exempt(dslCoveringCost)],
            .doubleTapCoord: [.onScreen: .behavior(["CoordinateTapRoutingTests.testNegativePointIsRefusedForDoubleTapToo"]),
                              .keyboard: .exempt(dslCoordIntent), .frontApp: .exempt(dslCoordIntent), .covering: .exempt(dslCoveringCost)],
            .dragCoord: [.onScreen: .behavior(["SwipePointToPointOffscreenTests.testStepRefusesWithoutFiring"]),
                         .keyboard: .exempt(dslCoordIntent), .frontApp: .exempt(dslCoordIntent), .covering: .exempt(dslCoveringCost)],
            .typeRefLess: [.frontApp: .behavior(["RefLessInputFrontAppNoteTests.testTypeIntoAnotherAppsFieldIsNotedButStillSent"])],
            .clearRefLess: [.frontApp: .behavior(["RefLessInputFrontAppNoteTests.testClearAndEnterAreNotedToo"])],
            .pressEnter: [.frontApp: .behavior(["RefLessInputFrontAppNoteTests.testClearAndEnterAreNotedToo"])],
        ],
        .mcp: [
            .tapRef: [.refIdentity: .behavior(["RefAppProvenanceTests.testTapRefusesARefTakenBeforeTheAppChanged",
                                               "MCPRefGuardTests.testTapRetargetsToTheFreshRefWhenTheElementMoved"]),
                      .keyboard: .behavior(["MCPRefGuardTests.testTapIsRefusedWhenTheCentreIsUnderTheKeyboard"]),
                      .covering: .behavior(["MCPRefGuardTests.testTapNamesTheNotificationCentreWhenThatIsWhatCovers"]),
                      .frontApp: .scan(["MCPSharedGuardParityTests.testPreFireGuardTableHasNoEmptyCell"]),
                      .bottomBand: .scan(["MCPSharedGuardParityTests.testEveryRefTouchHandlerClearsTheBottomGestureBand"])],
            .longPressRef: [.refIdentity: .scan(["TapRefGuardTests.testEveryRefPathGoesThroughTheSingleRetargetEntry"]),
                            .keyboard: .behavior(["MCPRefGuardTests.testTapIsRefusedWhenTheCentreIsUnderTheKeyboard"]),
                            .covering: .pending("verifiedRef を通るが振る舞いのテストが無い"),
                            .frontApp: .scan(["MCPSharedGuardParityTests.testPreFireGuardTableHasNoEmptyCell"]),
                            .bottomBand: .scan(["MCPSharedGuardParityTests.testEveryRefTouchHandlerClearsTheBottomGestureBand"])],
            .typeRef: [.refIdentity: .behavior(["TypeReplaceRelocateTests.testReplaceTypesIntoTheFieldFoundAgainAfterClearing"]),
                       .keyboard: .pure(["KeyboardRefusalFocusedFieldTests.testFocusedFieldIsNotRefusedForTypeAndClearInput"]),
                       .covering: .pending("verifiedRef を通るが振る舞いのテストが無い"),
                       .frontApp: .scan(["MCPSharedGuardParityTests.testPreFireGuardTableHasNoEmptyCell"])],
            .clearRef: [.refIdentity: .pending("verifiedRef を通るが照合の振る舞いのテストが無い"),
                        .keyboard: .pure(["KeyboardRefusalFocusedFieldTests.testFocusedFieldIsNotRefusedForTypeAndClearInput"]),
                        .covering: .pending("verifiedRef を通るが振る舞いのテストが無い"),
                        .frontApp: .scan(["MCPSharedGuardParityTests.testPreFireGuardTableHasNoEmptyCell"])],
            .dragRef: [.refIdentity: .scan(["TapRefGuardTests.testEveryRefPathGoesThroughTheSingleRetargetEntry"]),
                       .keyboard: .behavior(["MCPOutsideAppTreeSweepTests.testDragFromARefUnderTheKeyboardIsRefused"]),
                       .covering: .behavior(["MCPRefGuardTests.testRefGesturesNameTheSurfaceThatCoversTheApp"]),
                       .frontApp: .scan(["MCPSharedGuardParityTests.testEveryHandlerThatResolvesAnElementPassesTheRefGestureGuard"])],
            .doubleTapRef: [.refIdentity: .behavior(["MCPRefGuardTests.testDoubleTapWarnsWhenTheRetargetedElementHasADifferentLabel"]),
                            .keyboard: .behavior(["MCPRefGuardTests.testTapIsRefusedWhenTheCentreIsUnderTheKeyboard"]),
                            .covering: .behavior(["MCPRefGuardTests.testRefGesturesNameTheSurfaceThatCoversTheApp"]),
                            .frontApp: .scan(["MCPSharedGuardParityTests.testEveryHandlerThatResolvesAnElementPassesTheRefGestureGuard"]),
                            .bottomBand: .scan(["MCPSharedGuardParityTests.testEveryRefTouchHandlerClearsTheBottomGestureBand"])],
            .pinchRef: [.refIdentity: .scan(["TapRefGuardTests.testEveryRefPathGoesThroughTheSingleRetargetEntry"]),
                        .keyboard: .scan(["MCPSharedGuardParityTests.testEveryHandlerThatResolvesAnElementPassesTheRefGestureGuard"]),
                        .covering: .behavior(["MCPRefGuardTests.testRefGesturesNameTheSurfaceThatCoversTheApp"]),
                        .frontApp: .scan(["MCPSharedGuardParityTests.testEveryHandlerThatResolvesAnElementPassesTheRefGestureGuard"])],
            .tapCoord: [.onScreen: .behavior(["MCPOffscreenCoordinateGuardTests.testRejectsOffscreenTapWhenScreenIsKnown"]),
                        .keyboard: .behavior(["MCPKeyboardCoordinateWarningTests.testTapInsideTheKeyboardWarnsButFires"]),
                        .frontApp: .behavior(["MCPBatchTests.testCoordinateStepWarnsWhenAnotherAppIsInFront",
                                              "CoordinateFrontAppWarningTests.testEveryCoordinatePathAsksBeforeFiring"]),
                        .covering: .pending("iOS の coordinateFrontAppWarning が覆いを聞くが振る舞いのテストが無い")],
            .longPressCoord: [.onScreen: .behavior(["MCPOffscreenCoordinateGuardTests.testRejectsOffscreenLongPressWhenScreenIsKnown"]),
                              .keyboard: .behavior(["MCPKeyboardCoordinateWarningTests.testDoubleTapAndLongPressInsideTheKeyboardWarnToo"]),
                              .frontApp: .scan(["CoordinateFrontAppWarningTests.testEveryCoordinatePathAsksBeforeFiring"]),
                              .covering: .pending("iOS の coordinateFrontAppWarning が覆いを聞くが振る舞いのテストが無い")],
            .doubleTapCoord: [.onScreen: .behavior(["MCPOffscreenCoordinateGuardTests.testRejectsOffscreenDoubleTapWhenScreenIsKnown"]),
                              .keyboard: .behavior(["MCPKeyboardCoordinateWarningTests.testDoubleTapAndLongPressInsideTheKeyboardWarnToo"]),
                              .frontApp: .scan(["CoordinateFrontAppWarningTests.testEveryCoordinatePathAsksBeforeFiring"]),
                              .covering: .pending("iOS の coordinateFrontAppWarning が覆いを聞くが振る舞いのテストが無い")],
            .dragCoord: [.onScreen: .behavior(["MCPOffscreenCoordinateGuardTests.testRejectsOffscreenDragStartWhenScreenIsKnown"]),
                         .keyboard: .behavior(["MCPOutsideAppTreeSweepTests.testCoordinateDragStartingOnTheKeyboardWarns"]),
                         .frontApp: .scan(["CoordinateFrontAppWarningTests.testEveryCoordinatePathAsksBeforeFiring"]),
                         .covering: .pending("iOS の coordinateFrontAppWarning が覆いを聞くが振る舞いのテストが無い")],
            .pinchCoord: [.onScreen: .behavior(["MCPOffscreenCoordinateGuardTests.testRejectsOffscreenPinchCentreEvenBeforeASnapshot"]),
                          .keyboard: .behavior(["MCPKeyboardCoordinateWarningTests.testRereadsTheTreeAfterOwnActionBeforeFiring"]),
                          .frontApp: .scan(["CoordinateFrontAppWarningTests.testEveryCoordinatePathAsksBeforeFiring"]),
                          .covering: .pending("iOS の coordinateFrontAppWarning が覆いを聞くが振る舞いのテストが無い")],
            .typeRefLess: [.frontApp: .scan(["MCPSharedGuardParityTests.testPreFireGuardTableHasNoEmptyCell",
                                             "TapRefGuardTests.testGuardsAreWiredIntoEveryReturningPath"])],
            .clearRefLess: [.frontApp: .scan(["MCPSharedGuardParityTests.testPreFireGuardTableHasNoEmptyCell"])],
            .pressEnter: [.frontApp: .scan(["MCPSharedGuardParityTests.testPreFireGuardTableHasNoEmptyCell"])],
        ],
        .cli: [
            .tapRef: [.refIdentity: .scan(["RefFireGateWiringTests.testEveryRefFiringCommandPassesTheGateBeforeFiring"]),
                      .keyboard: .scan(["RefFireGateWiringTests.testEveryRefFiringCommandPassesTheGateBeforeFiring"]),
                      .covering: .exempt(runnerRefusesBackground), .frontApp: .exempt(cliNoSession),
                      .bottomBand: .scan(["RefFireGateWiringTests.testRefTapAndPressClearTheBottomGestureBand"])],
            .longPressRef: [.refIdentity: .scan(["RefFireGateWiringTests.testEveryRefFiringCommandPassesTheGateBeforeFiring"]),
                            .keyboard: .scan(["RefFireGateWiringTests.testEveryRefFiringCommandPassesTheGateBeforeFiring"]),
                            .covering: .exempt(runnerRefusesBackground), .frontApp: .exempt(cliNoSession),
                            .bottomBand: .scan(["RefFireGateWiringTests.testRefTapAndPressClearTheBottomGestureBand"])],
            .typeRef: [.refIdentity: .scan(["RefFireGateWiringTests.testEveryRefFiringCommandPassesTheGateBeforeFiring"]),
                       .keyboard: .scan(["RefFireGateWiringTests.testEveryRefFiringCommandPassesTheGateBeforeFiring"]),
                       .covering: .exempt(runnerRefusesBackground), .frontApp: .exempt(cliNoSession)],
            .tapCoord: [.onScreen: .pending("isPointOnScreen を通るが CLI の経路を縛るテストが無い"),
                        .keyboard: .pure(["CoordinateGuardsTests.testKeyboardFrameContainingPoint"]),
                        .covering: .exempt(runnerRefusesBackground), .frontApp: .exempt(cliNoSession)],
            .typeRefLess: [.frontApp: .exempt(cliNoSession)],
        ],
        .live: [
            .tapRef: [.refIdentity: .scan(["LiveRefAndDragGuardWiringTests.testRefOperationsCheckWhatTheUserSaw",
                                           "LiveRefAndDragGuardWiringTests.testBottomBandTapChecksWhatTheUserSawBeforeFoldingToCoordinates"]),
                      .keyboard: .scan(["FireEntryPathTableTests.testLiveRefFiringCasesPassRequireFireable"]),
                      .covering: .exempt(liveFollows), .frontApp: .exempt(liveFollows),
                      .bottomBand: .scan(["ApiLiveBottomGestureBandWiringTests.testRefTapAndDoubleTapClearTheBottomGestureBand"])],
            .typeRef: [.refIdentity: .scan(["LiveRefAndDragGuardWiringTests.testRefOperationsCheckWhatTheUserSaw"]),
                       .keyboard: .scan(["FireEntryPathTableTests.testLiveRefFiringCasesPassRequireFireable"]),
                       .covering: .exempt(liveFollows), .frontApp: .exempt(liveFollows)],
            .clearRef: [.refIdentity: .scan(["LiveRefAndDragGuardWiringTests.testRefOperationsCheckWhatTheUserSaw"]),
                        .keyboard: .scan(["FireEntryPathTableTests.testLiveRefFiringCasesPassRequireFireable"]),
                        .covering: .exempt(liveFollows), .frontApp: .exempt(liveFollows)],
            .doubleTapRef: [.refIdentity: .scan(["LiveRefAndDragGuardWiringTests.testRefOperationsCheckWhatTheUserSaw"]),
                            .keyboard: .scan(["FireEntryPathTableTests.testLiveRefFiringCasesPassRequireFireable"]),
                            .covering: .exempt(liveFollows), .frontApp: .exempt(liveFollows),
                            .bottomBand: .scan(["ApiLiveBottomGestureBandWiringTests.testRefTapAndDoubleTapClearTheBottomGestureBand"])],
            .pinchRef: [.refIdentity: .scan(["LiveRefAndDragGuardWiringTests.testRefOperationsCheckWhatTheUserSaw"]),
                        .keyboard: .scan(["FireEntryPathTableTests.testLiveRefFiringCasesPassRequireFireable"]),
                        .covering: .exempt(liveFollows), .frontApp: .exempt(liveFollows)],
            .tapCoord: [.onScreen: .scan(["ApiLiveCoordinateOnScreenGuardTests.testTapCoordinateFormGoesThroughTheGuardBeforeTouchingTheDriver"]),
                        .keyboard: .exempt(liveHumanCoord), .covering: .exempt(liveFollows), .frontApp: .exempt(liveFollows)],
            .longPressCoord: [.onScreen: .scan(["ApiLiveCoordinateOnScreenGuardTests.testPressCoordinateFormGoesThroughTheGuardBeforeTouchingTheDriver"]),
                              .keyboard: .exempt(liveHumanCoord), .covering: .exempt(liveFollows), .frontApp: .exempt(liveFollows)],
            .doubleTapCoord: [.onScreen: .scan(["ApiLiveCoordinateOnScreenGuardTests.testDoubleTapCoordinateFormGoesThroughTheGuardBeforeTouchingTheDriver"]),
                              .keyboard: .exempt(liveHumanCoord), .covering: .exempt(liveFollows), .frontApp: .exempt(liveFollows)],
            .dragCoord: [.onScreen: .scan(["ApiLiveCoordinateOnScreenGuardTests.testDragChecksBothEndpointsBeforeTouchingTheDriver"]),
                         .keyboard: .exempt(liveHumanCoord), .covering: .exempt(liveFollows), .frontApp: .exempt(liveFollows)],
            .typeRefLess: [.frontApp: .exempt(liveFollows)],
            .clearRefLess: [.frontApp: .exempt(liveFollows)],
        ],
    ]

    /// 未対応(確かめるテストが無いマス)の数。**直したら下げる・増やすなら理由を書いて上げる**
    static let pendingCount = 10

    // MARK: - テスト

    func testEveryApplicableCellIsDecided() {
        var missing: [String] = []
        var extra: [String] = []
        for entrance in Entrance.allCases {
            let rows = Self.table[entrance] ?? [:]
            let declared = Self.ops[entrance] ?? []
            for op in Op.allCases {
                let row = rows[op] ?? [:]
                for check in Check.allCases {
                    let key = "\(entrance).\(op).\(check)"
                    let wanted = declared.contains(op) && Self.applies(check, to: op)
                    if wanted && row[check] == nil { missing.append(key) }
                    if !wanted && row[check] != nil { extra.append(key) }
                }
            }
        }
        XCTAssertEqual(missing, [], "空のマス: 入口に操作があり検査が当てはまるのに決まっていない")
        XCTAssertEqual(extra, [], "当てはまらないマスに値がある(操作が入口に無い・検査が当てはまらない)")
    }

    func testPendingCountIsPinned() {
        var pending: [String] = []
        for (entrance, rows) in Self.table {
            for (op, cells) in rows {
                for (check, cell) in cells { if case .pending = cell { pending.append("\(entrance).\(op).\(check)") } }
            }
        }
        XCTAssertEqual(pending.count, Self.pendingCount, pending.sorted().joined(separator: "\n"))
    }

    /// 名指したテストが `class` か `extension` の中に実在する(改名・削除で表が嘘にならない)
    func testNamedTestsExist() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
            .map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
        XCTAssertGreaterThan(files.count, 100, "走査が Tests に届いていない")
        var names: Set<String> = []
        for rows in Self.table.values {
            for cells in rows.values {
                for cell in cells.values {
                    switch cell {
                    case .behavior(let tests), .scan(let tests), .pure(let tests): names.formUnion(tests)
                    case .exempt, .pending: break
                    }
                }
            }
        }
        var absent: [String] = []
        for name in names {
            let parts = name.split(separator: ".").map(String.init)
            guard parts.count == 2 else { absent.append(name); continue }
            let found = files.contains { text in
                (text.contains("class \(parts[0])") || text.contains("extension \(parts[0])"))
                    && text.contains("func \(parts[1])(")
            }
            if !found { absent.append(name) }
        }
        XCTAssertEqual(absent.sorted(), [], "表が名指すテストが見つからない")
    }
}
