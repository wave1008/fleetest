import XCTest
@testable import FTCore

/// type の事後の照合は `TypedInputCheck` の1つの入口を通る。判定の中身と、経路の表(操作 × 経路 × 入口)を固定する。
final class TypedInputCheckRoutesTests: XCTestCase {
    private func el(_ ref: Int, _ type: String, id: String?, value: String?, focused: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: value, placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 0, width: 300, height: 50), depth: 1, focused: focused)
    }

    // MARK: ref なし(前の値を焦点の欄から取る)

    /// 伏せ字 5 つの欄へ「あい」を打って 5 のまま = 全部落ちた。前の値を渡さない旧経路は本文より長い欄を素通りしていた
    func testRefLessAppendToMaskedFieldThatDroppedKanaFails() {
        let focused = el(1, "secureTextField", id: "password", value: "•••••", focused: true)
        let prior = TypedInputCheck.Prior(focusedIn: [focused])
        XCTAssertEqual(prior.valueBefore, "•••••")
        XCTAssertNotNil(TypedInputCheck.failure(prior: prior, text: "あい", isAndroid: false, after: [focused]))
        // 前の値が無いと通ってしまう(入口が前の値を取る理由)
        XCTAssertNil(TypedInputCheck.failure(prior: TypedInputCheck.Prior(focusedIn: nil), text: "あい", isAndroid: false,
                                             after: [focused]))
    }

    /// 焦点を取り戻した欄は置き換わる(数 = 本文)・追記(前 + 本文)は通す(324ff352 の退行を繰り返さない)
    func testReplacedOrAppendedMaskedFieldPasses() {
        let before = el(1, "secureTextField", id: "password", value: "•••", focused: true)
        let prior = TypedInputCheck.Prior(focusedIn: [before])
        for count in [2, 5] {
            let after = el(1, "secureTextField", id: "password", value: String(repeating: "•", count: count), focused: true)
            XCTAssertNil(TypedInputCheck.failure(prior: prior, text: "かな", isAndroid: false, after: [after]), "\(count)")
        }
    }

    func testFocusedPriorIsEmptyWhenFocusIsNotUnique() {
        let a = el(1, "secureTextField", id: "a", value: "•••", focused: true)
        let b = el(2, "textField", id: "b", value: "x", focused: true)
        XCTAssertEqual(TypedInputCheck.Prior(focusedIn: [a, b]).valueBefore, "")
        XCTAssertEqual(TypedInputCheck.Prior(focusedIn: [a]).treeBefore.count, 1)
    }

    func testPriorReadIsOnlyNeededWhereTheCheckCanFire() {
        XCTAssertTrue(TypedInputCheck.needsPriorRead(text: "かな", isAndroid: false))
        XCTAssertFalse(TypedInputCheck.needsPriorRead(text: "abc", isAndroid: false))
        XCTAssertFalse(TypedInputCheck.needsPriorRead(text: "かな", isAndroid: true))
        XCTAssertFalse(TypedInputCheck.needsPriorRead(text: "か\nな", isAndroid: false))
    }

    // MARK: ref あり(replace は消した後なので前の値は空)

    func testReplaceDiscardsPriorValue() {
        let target = el(1, "secureTextField", id: "password", value: "•••••")
        let replaced = TypedInputCheck.Prior(target: target, priorValue: "•••••", replace: true, treeBefore: [target])
        XCTAssertEqual(replaced.valueBefore, "")
        let appended = TypedInputCheck.Prior(target: target, priorValue: "•••••", replace: false, treeBefore: [target])
        XCTAssertEqual(appended.valueBefore, "•••••")
        XCTAssertNotNil(TypedInputCheck.failure(prior: appended, text: "あい", isAndroid: false, after: [target]))
    }

    // MARK: 経路の表(ソース走査。空の升・直呼びで落ちる)

    /// 操作 × 経路 × 入口。DSL のロケータ有り(typeDriver・主経路)・ロケータ無し(焦点救済・素)・MCP の ft_type が入口を通る。
    /// ft_batch の type は DSL の経路。判定を呼び手が直に呼ばない(入口 `TypedInputCheck` と文言だけ)
    func testEveryTypePathGoesThroughTheSingleEntry() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }
        // (経路, ファイル, 入口の呼び出し, 件数)
        let routes: [(String, String, String, Int)] = [
            ("DSL ロケータ有り: typeDriver 経路 + 主経路", "Sources/FTCore/StepExecutor+Actions.swift", "await typedInputFailure(", 2),
            ("DSL ロケータ無し: 焦点救済 + 素", "Sources/FTCore/StepExecutor+DirectActions.swift", "await typedInputFailure(", 2),
            ("DSL ロケータ無し: 打つ前の値は焦点の欄から", "Sources/FTCore/StepExecutor+DirectActions.swift", "await focusedPriorForTyping(", 1),
            ("DSL ロケータ有り: 打つ前の値", "Sources/FTCore/StepExecutor+Actions.swift", "TypedInputCheck.Prior(target:", 1),
            ("MCP ft_type: 判定", "Sources/fleetest-mcp/MCPServer+ScreenTools.swift", "TypedInputCheck.failure(", 1),
            ("MCP ft_type ref あり: 打つ前の値", "Sources/fleetest-mcp/MCPServer+ScreenTools.swift", "TypedInputCheck.Prior(target:", 1),
            ("MCP ft_type ref なし: 打つ前の値", "Sources/fleetest-mcp/MCPServer+ScreenTools.swift", "TypedInputCheck.Prior(focusedIn:", 2),
        ]
        for (name, path, needle, expected) in routes {
            XCTAssertEqual(count(needle, in: try source(path)), expected, "\(name): \(path) の \(needle)")
        }
        // 個々の判定を呼び手が直に呼ばない(入口を迂回する経路が増えたら落ちる)
        let entry = "Sources/FTCore/TypedInputCheck.swift"
        let direct = ["TypedInputVerdict.maskedShortfall(", "TypedInputVerdict.newlineMisdelivery(",
                      "TypedInputVerdict.wantsMaskedCheck(", "TypedInputVerdict.maskedField("]
        let fm = FileManager.default
        for dir in ["Sources/FTCore", "Sources/fleetest-mcp", "Sources/fleetest"] {
            guard let names = try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(dir).path) else { continue }
            for name in names where name.hasSuffix(".swift") {
                let path = "\(dir)/\(name)"
                if path == entry || path == "Sources/FTCore/TypedInputVerdict.swift" { continue }
                let text = try source(path)
                for needle in direct {
                    XCTAssertEqual(count(needle, in: text), 0, "\(path) が入口を通さず \(needle) を呼んでいる")
                }
            }
        }
    }
}
