// BackEffect の純ロジック(back の前後で木が同一かの判定)を検証する。デバイスに触れない。

import XCTest
@testable import FTCore

final class BackEffectTests: XCTestCase {
    private func element(label: String) -> ElementInfo {
        ElementInfo(ref: 1, type: "staticText", identifier: nil, label: label, value: nil,
                   placeholder: nil, enabled: true,
                   frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 0)
    }

    private let screenA = [ElementInfo]()  // 空の木でも指紋は取れる(要素数0も1つの指紋)
    private var treeA: [ElementInfo] { [element(label: "A")] }
    private var treeB: [ElementInfo] { [element(label: "B")] }

    private func snap(_ elements: [ElementInfo], keyboard: FTRect? = nil) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 1080, height: 2340),
                         elements: elements, truncatedCount: 0, keyboardFrame: keyboard)
    }

    // MARK: - shouldWarn: 同一 → 注記あり

    func testShouldWarnWhenAllObservationsAreIdenticalToBefore() {
        XCTAssertTrue(BackEffect.shouldWarn(before: snap(treeA), afterObservations: [snap(treeA)]))
        // ポーリングで複数回撮っても、全部同一なら警告(MCP のポーリング経路を模した形)
        XCTAssertTrue(BackEffect.shouldWarn(before: snap(treeA), afterObservations: [snap(treeA), snap(treeA), snap(treeA)]))
    }

    // MARK: - shouldWarn: 相違 → 注記なし

    func testShouldWarnIsFalseWhenAnyObservationDiffersFromBefore() {
        XCTAssertFalse(BackEffect.shouldWarn(before: snap(treeA), afterObservations: [snap(treeB)]))
        // 最初は同一でも、途中で変わっていれば back は効いたので警告しない
        XCTAssertFalse(BackEffect.shouldWarn(before: snap(treeA), afterObservations: [snap(treeA), snap(treeB)]))
    }

    // MARK: - shouldWarn: 観測が0件 → 黙る

    func testShouldWarnIsFalseWhenThereAreNoObservations() {
        XCTAssertFalse(BackEffect.shouldWarn(before: snap(treeA), afterObservations: []))
    }

    // MARK: - treesAreIdentical(shouldWarn の下敷き)

    func testTreesAreIdenticalMatchesOnFingerprintNotIdentity() {
        // 同じ内容から作った別々の配列でも、指紋が同じなら同一と判定する
        XCTAssertTrue(BackEffect.treesAreIdentical(before: [element(label: "A")],
                                                    after: [element(label: "A")]))
        XCTAssertFalse(BackEffect.treesAreIdentical(before: treeA, after: treeB))
    }

    func testEmptyTreesAreIdenticalToEachOther() {
        XCTAssertTrue(BackEffect.treesAreIdentical(before: screenA, after: screenA))
    }

    // MARK: - 文言: MCP/DSL で末尾だけ違う中核文を共有する

    func testNoteSharesTheCoreSummaryAcrossCallers() {
        let mcpText = BackEffect.note(advice: BackEffect.mcpAdvice)
        let dslText = BackEffect.note(advice: BackEffect.dslAdvice)
        XCTAssertTrue(mcpText.hasPrefix(BackEffect.summary))
        XCTAssertTrue(dslText.hasPrefix(BackEffect.summary))
        XCTAssertNotEqual(mcpText, dslText)
        XCTAssertTrue(mcpText.contains("tap it instead"))
        XCTAssertTrue(dslText.contains("tap() it instead of back()"))
        // 従えない案内(繰り返し)を言わない(39周目 im4 F3)
        XCTAssertFalse(mcpText.contains("again") || dslText.contains("again"), mcpText + dslText)
    }

    /// **キーボードを閉じただけの back は「効いた」**(キーボードはアプリの木の外。Android の back は最初にキーボードだけを閉じる)。
    /// 数えないと「効かなかった・もう一度 back を」と言い、従うと2回目で画面まで戻る
    func testClosingTheKeyboardCountsAsAnEffect() {
        let keyboard = FTRect(x: 0, y: 1541, width: 1080, height: 799)
        XCTAssertFalse(BackEffect.shouldWarn(before: snap(treeA, keyboard: keyboard), afterObservations: [snap(treeA)]))
        XCTAssertTrue(BackEffect.shouldWarn(before: snap(treeA, keyboard: keyboard),
                                            afterObservations: [snap(treeA, keyboard: keyboard)]))
        // 画面の外の矩形(隠れたキーボード)は「出ていない」と同じ
        XCTAssertTrue(BackEffect.shouldWarn(before: snap(treeA),
                                            afterObservations: [snap(treeA, keyboard: FTRect(x: 0, y: 2400, width: 1080, height: 799))]))
    }

    // MARK: - stayedOnSameScreen: 左端のスワイプが中身に届いて同じ画面に留まった(28周目 iultra F1)

    private func idEl(_ id: String, _ label: String, type: String = "staticText") -> ElementInfo {
        ElementInfo(ref: 1, type: type, identifier: id, label: label, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 0)
    }

    func testSwipeThatReachedTheContentIsTheSameScreen() {
        let before = snap([idEl("txt_title", "ジェスチャ"), idEl("pad_swipe", ""), idEl("txt_swipe", "swipe=none")])
        let after = snap([idEl("txt_title", "ジェスチャ"), idEl("pad_swipe", ""), idEl("txt_swipe", "swipe=right")])
        XCTAssertFalse(BackEffect.shouldWarn(before: before, afterObservations: [after]), "木は変わっている")
        XCTAssertTrue(BackEffect.stayedOnSameScreen(before: before, after: after))
    }

    func testGoingBackIsNotTheSameScreen() {
        let before = snap([idEl("txt_title", "ジェスチャ"), idEl("pad_swipe", ""), idEl("txt_swipe", "swipe=none")])
        let home = snap([idEl("txt_home_marker", "ホーム"), idEl("nav_gesture", "ジェスチャ"), idEl("nav_input", "入力")])
        XCTAssertFalse(BackEffect.stayedOnSameScreen(before: before, after: home))
    }

    func testANavigationBackButtonOrTooFewIdentifiersStaySilent() {
        let withButton = snap([idEl("BackButton", "戻る", type: "button"), idEl("a", "a"), idEl("b", "b")])
        XCTAssertFalse(BackEffect.stayedOnSameScreen(before: withButton, after: withButton), "戻るボタンは押すので対象外")
        let sparse = snap([idEl("a", "a"), idEl("b", "b")])
        XCTAssertFalse(BackEffect.stayedOnSameScreen(before: sparse, after: sparse), "識別子が少ない画面では言えない")
    }

    /// Android の最初の画面での back: 木の持ち主が対象アプリからランチャーへ替わった
    func testLeftTheAppWhenTheTreeOwnerIsNoLongerTheApp() {
        let app = "com.ftester.e2e.android"
        XCTAssertTrue(BackEffect.leftTheApp(afterOwner: "com.google.android.apps.nexuslauncher", expected: [app]))
        XCTAssertFalse(BackEffect.leftTheApp(afterOwner: app, expected: [app]))
        // 最後に起こしたアプリも期待に入る(launchApp("別アプリ") の後の back)
        XCTAssertFalse(BackEffect.leftTheApp(afterOwner: "com.android.settings", expected: [app, "com.android.settings"]))
        // 読めない・システムのダイアログは言わない
        XCTAssertFalse(BackEffect.leftTheApp(afterOwner: nil, expected: [app]))
        XCTAssertFalse(BackEffect.leftTheApp(afterOwner: "", expected: [app]))
        XCTAssertFalse(BackEffect.leftTheApp(afterOwner: "com.google.android.permissioncontroller", expected: [app]))
    }

    // MARK: - closedKeyboardOnly

    private func snapKeyboard(_ elements: [ElementInfo], shown: Bool?, frame: FTRect? = nil) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 1080, height: 2340),
                         elements: elements, truncatedCount: 0, keyboardShown: shown, keyboardFrame: frame)
    }

    func testClosedKeyboardOnlyWhenKeyboardWentAwayAndTreeIsSame() {
        let open = snapKeyboard(treeA, shown: true, frame: FTRect(x: 0, y: 1500, width: 1080, height: 840))
        let closed = snapKeyboard(treeA, shown: false)
        XCTAssertTrue(BackEffect.closedKeyboardOnly(before: open, after: closed))
        // back の効き判定はキーボードの出入りを「効いた」と数える = 既存の ineffective 注記は黙ったまま
        XCTAssertFalse(BackEffect.shouldWarn(before: open, afterObservations: [closed]))
        XCTAssertTrue(BackEffect.keyboardClosedNote.contains("closed the soft keyboard"))
        XCTAssertTrue(BackEffect.keyboardClosedNote.contains("did not go back"))
    }

    /// View の画面: キーボードが閉じると窓が広がって枠が変わり、隠れていた行も現れる = それでも同じ画面(43周目 amax が木で観測)
    func testClosedKeyboardOnlyIgnoresTheLayoutChangeOfAResizedWindow() {
        let field = ElementInfo(ref: 1, type: "textField", identifier: "field_title", label: "タイトル", value: "abc", placeholder: nil,
                                enabled: true, frame: FTRect(x: 0, y: 200, width: 1080, height: 120), depth: 1)
        let container = ElementInfo(ref: 2, type: "other", identifier: "content", label: nil, value: nil, placeholder: nil,
                                    enabled: true, frame: FTRect(x: 0, y: 0, width: 1280, height: 1332), depth: 0)
        var grown = container
        grown.frame = FTRect(x: 0, y: 0, width: 1280, height: 2268)
        let revealed = ElementInfo(ref: 3, type: "button", identifier: "btn_open_panel", label: "パネル", value: nil, placeholder: nil,
                                   enabled: true, frame: FTRect(x: 0, y: 1800, width: 400, height: 120), depth: 1)
        let open = snapKeyboard([container, field], shown: true, frame: FTRect(x: 0, y: 1500, width: 1080, height: 840))
        XCTAssertTrue(BackEffect.closedKeyboardOnly(before: open, after: snapKeyboard([grown, field, revealed], shown: false)),
                      "窓が広がった同じ画面を別の画面と読んだ")
        // id だけのレイアウト容器は閉じた後の木から落ちる(E2EY-Android の #nav_host_fragment)
        XCTAssertTrue(BackEffect.closedKeyboardOnly(before: open, after: snapKeyboard([field, revealed], shown: false)),
                      "id だけの容器が落ちた同じ画面を別の画面と読んだ")
        let previous = ElementInfo(ref: 1, type: "button", identifier: "btn_open_editor", label: "編集画面を開く", value: nil,
                                   placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 200, width: 600, height: 120), depth: 1)
        XCTAssertFalse(BackEffect.closedKeyboardOnly(before: open, after: snapKeyboard([previous], shown: false)), "前の画面へ戻った")
    }

    func testClosedKeyboardOnlyIsFalseWhenTheScreenChangedOrKeyboardStateIsUnknown() {
        let open = snapKeyboard(treeA, shown: true, frame: FTRect(x: 0, y: 1500, width: 1080, height: 840))
        XCTAssertFalse(BackEffect.closedKeyboardOnly(before: open, after: snapKeyboard(treeB, shown: false)), "画面が変わった")
        XCTAssertFalse(BackEffect.closedKeyboardOnly(before: open, after: snapKeyboard(treeA, shown: nil)), "後が分からない")
        XCTAssertFalse(BackEffect.closedKeyboardOnly(before: snapKeyboard(treeA, shown: false), after: snapKeyboard(treeA, shown: false)),
                       "前に出ていない")
        XCTAssertFalse(BackEffect.closedKeyboardOnly(before: open, after: open), "閉じていない")
        // 画面の外の矩形は隠れたキーボード(出ていない)
        let hidden = snapKeyboard(treeA, shown: true, frame: FTRect(x: 0, y: 2400, width: 1080, height: 840))
        XCTAssertFalse(BackEffect.closedKeyboardOnly(before: hidden, after: snapKeyboard(treeA, shown: false)))
    }

    /// DSL の back() が Android でだけ closedKeyboardOnly を注記へつなぐ(ソース走査 = 配線の固定)
    func testDSLBackWiresClosedKeyboardNoteForAndroid() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FTDSL/CommandsAppControl.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("core.platform == \"android\", BackEffect.closedKeyboardOnly(before: before, after: after)"))
        XCTAssertTrue(source.contains("observedNote = .backClosedKeyboard"))
        XCTAssertEqual(StepNote.backClosedKeyboard.rawValue, "back-closed-keyboard")
    }
}
