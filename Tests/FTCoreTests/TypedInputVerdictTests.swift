import XCTest
@testable import FTCore

/// type / clearInput の事後の照合(DSL・MCP・ft_batch が共有する `TypedInputVerdict`)
final class TypedInputVerdictTests: XCTestCase {
    private func el(_ ref: Int, _ type: String, id: String?, value: String? = nil, focused: Bool? = nil,
                    y: Double = 0, height: Double = 50) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: value, placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: y, width: 300, height: height), depth: 1, focused: focused)
    }

    // MARK: maskedShortfall(打つ前の値)

    /// 値が既にある secure 欄へ非 ASCII だけを打って数が動かない(受けなかった文字が ok になっていた)
    func testNonASCIIIntoAFieldThatAlreadyHoldsMasksFailsWhenTheCountDidNotMove() {
        XCTAssertNotNil(TypedInputVerdict.maskedShortfall(priorValue: "•••", afterValue: "•••", text: "かな"))
        XCTAssertNotNil(TypedInputVerdict.maskedShortfall(priorValue: "••••", afterValue: "••••", text: "あい"))
    }

    /// 混在(ASCII だけ受けた): 追記なら前 + 1 で本文の分に足りない
    func testPartialAppendFails() {
        XCTAssertNotNil(TypedInputVerdict.maskedShortfall(priorValue: "••••", afterValue: "•••••", text: "xあ"))
    }

    /// 置き換わった(本文の文字数ちょうど)・追記された(前 + 本文)はどちらも通す = 焦点を取り戻すと置き換わる欄を赤にしない
    func testReplacedOrAppendedPasses() {
        XCTAssertNil(TypedInputVerdict.maskedShortfall(priorValue: "•••", afterValue: "••", text: "かな"))
        XCTAssertNil(TypedInputVerdict.maskedShortfall(priorValue: "•••", afterValue: "•••••", text: "かな"))
        XCTAssertNil(TypedInputVerdict.maskedShortfall(priorValue: "•••", afterValue: "•••••••", text: "かな"))
        // ASCII だけの本文は前の数を使わない(置き換わって前より減る)
        XCTAssertNil(TypedInputVerdict.maskedShortfall(priorValue: "•••", afterValue: "••", text: "de"))
    }

    func testPriorValueUnknownKeepsTheOldRule() {
        XCTAssertNotNil(TypedInputVerdict.maskedShortfall(priorValue: nil, afterValue: "", text: "かな"))
        XCTAssertNil(TypedInputVerdict.maskedShortfall(priorValue: nil, afterValue: "", text: "abc"))
        XCTAssertNil(TypedInputVerdict.maskedShortfall(priorValue: nil, afterValue: "•••", text: "かな"))
    }

    /// 末尾改行・改行入りは見ない(送信が走りうる)
    func testNewlineTextIsNotJudged() {
        XCTAssertNil(TypedInputVerdict.maskedShortfall(priorValue: nil, afterValue: "", text: "あ\n"))
    }

    // MARK: 門と対象の欄

    func testGate() {
        let secure = el(1, "secureTextField", id: "p")
        let plain = el(2, "textField", id: "t")
        XCTAssertTrue(TypedInputVerdict.wantsMaskedCheck(target: secure, text: "abc", isAndroid: false))
        XCTAssertTrue(TypedInputVerdict.wantsMaskedCheck(target: secure, text: "abc", isAndroid: true))
        XCTAssertTrue(TypedInputVerdict.wantsMaskedCheck(target: plain, text: "あ", isAndroid: false))
        XCTAssertTrue(TypedInputVerdict.wantsMaskedCheck(target: nil, text: "あ", isAndroid: false))
        XCTAssertFalse(TypedInputVerdict.wantsMaskedCheck(target: plain, text: "abc", isAndroid: false))
        XCTAssertFalse(TypedInputVerdict.wantsMaskedCheck(target: plain, text: "あ", isAndroid: true))
        XCTAssertFalse(TypedInputVerdict.wantsMaskedCheck(target: secure, text: "あ\n", isAndroid: false))
        XCTAssertFalse(TypedInputVerdict.wantsMaskedCheck(target: secure, text: "", isAndroid: false))
    }

    /// Flutter: 焦点が入る前は textField・入った後は secureTextField(同じ id)
    func testFieldThatBecameSecureAfterFocusIsFound() {
        let before = el(1, "textField", id: "field_password")
        let after = el(1, "secureTextField", id: "field_password", value: "••", focused: true)
        XCTAssertEqual(TypedInputVerdict.maskedField(target: before, in: [after])?.type, "secureTextField")
    }

    /// Flutter: id が外側の other に付き、secure 欄は id を持たない子
    func testSecureFieldInsideAnOuterContainerIsFound() {
        let outer = el(1, "other", id: "field_password", y: 355, height: 56)
        let inner = el(2, "secureTextField", id: nil, value: "", focused: true, y: 360, height: 46)
        let elsewhere = el(3, "secureTextField", id: nil, focused: true, y: 700)
        XCTAssertEqual(TypedInputVerdict.maskedField(target: outer, in: [outer, inner])?.ref, 2)
        // 枠の外の secure 欄は拾わない
        XCTAssertNil(TypedInputVerdict.maskedField(target: outer, in: [outer, elsewhere]))
    }

    func testOrdinaryFieldAndFocusedSecureWithoutTarget() {
        let plain = el(1, "textField", id: "t", value: "x", focused: true)
        XCTAssertNil(TypedInputVerdict.maskedField(target: plain, in: [plain]))
        XCTAssertNil(TypedInputVerdict.maskedField(target: nil, in: [plain]))
        let secure = el(2, "secureTextField", id: "p", value: "••", focused: true)
        XCTAssertEqual(TypedInputVerdict.maskedField(target: nil, in: [secure])?.ref, 2)
    }

    // MARK: 改行入りの宛先

    func testNewlineMisdeliveryNamesTheOtherField() {
        let target = el(1, "textView", id: "multi", value: "")
        let bottomBefore = el(2, "textField", id: "bottom", value: "X", focused: true, y: 100)
        let bottomAfter = el(2, "textField", id: "bottom", value: "Xa b", focused: true, y: 100)
        XCTAssertNotNil(TypedInputVerdict.newlineMisdelivery(
            target: target, before: [target, bottomBefore], after: [target, bottomAfter], valueBefore: "", text: "a\nb"))
        // 対象が変わったなら宛先は合っている
        let targetAfter = el(1, "textView", id: "multi", value: "a\nb")
        XCTAssertNil(TypedInputVerdict.newlineMisdelivery(
            target: target, before: [target, bottomBefore], after: [targetAfter, bottomAfter], valueBefore: "", text: "a\nb"))
        // 末尾が改行の本文・改行なしは見ない
        XCTAssertNil(TypedInputVerdict.newlineMisdelivery(
            target: target, before: [target, bottomBefore], after: [target, bottomAfter], valueBefore: "", text: "a\n"))
        XCTAssertNil(TypedInputVerdict.newlineMisdelivery(
            target: target, before: [target, bottomBefore], after: [target, bottomAfter], valueBefore: "", text: "ab"))
    }

    // MARK: 消した後に別の欄が空になる

    func testClearThatEmptiedAnotherFieldIsDetected() {
        let target = el(1, "textView", id: "multi", value: "Q")
        let otherBefore = el(2, "textField", id: "bottom", value: "XY", y: 100)
        let targetAfter = el(1, "textView", id: "multi", value: "")
        let otherAfter = el(2, "textField", id: "bottom", value: "", y: 100)
        XCTAssertEqual(TypedInputVerdict.otherInputCleared(
            target: target, before: [target, otherBefore], after: [targetAfter, otherAfter])?.identifier, "bottom")
        // 他の欄が変わらない・値が変わっても空でない・元から空は赤にしない
        XCTAssertNil(TypedInputVerdict.otherInputCleared(
            target: target, before: [target, otherBefore], after: [targetAfter, otherBefore]))
        let otherChanged = el(2, "textField", id: "bottom", value: "Z", y: 100)
        XCTAssertNil(TypedInputVerdict.otherInputCleared(
            target: target, before: [target, otherBefore], after: [targetAfter, otherChanged]))
        let emptyBefore = el(2, "textField", id: "bottom", value: "", y: 100)
        XCTAssertNil(TypedInputVerdict.otherInputCleared(
            target: target, before: [target, emptyBefore], after: [targetAfter, otherAfter]))
    }

    // MARK: 配線(ソース走査)

    /// 判定は1箇所。DSL の全経路(typeDriver・主経路・ロケータ無し)と MCP の ft_type / ft_clear_input が呼ぶ
    func testEveryPathCallsTheSharedVerdict() throws {
        func source(_ path: String) throws -> String {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let mcp = try source("Sources/fleetest-mcp/MCPServer+ScreenTools.swift")
        for needle in ["TypedInputVerdict.otherInputCleared("] {
            XCTAssertTrue(mcp.contains(needle), "MCP が \(needle) を呼んでいない")
        }
        XCTAssertEqual(mcp.components(separatedBy: "TypedInputVerdict.otherInputCleared(").count - 1, 2, "ft_type replace と ft_clear_input")
    }
}
