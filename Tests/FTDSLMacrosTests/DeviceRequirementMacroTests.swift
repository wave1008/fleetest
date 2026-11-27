import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest
@testable import FTDSLMacros

/// @RequiresDevice / @ExcludesDevice(DR-237)の展開とコンパイルエラー
final class DeviceRequirementMacroTests: XCTestCase {
    let macros: [String: MacroSpec] = [
        "TestClass": MacroSpec(type: TestClassMacro.self, conformances: ["FTDSL.FTTestClassDefinition"]),
        "Test": MacroSpec(type: TestMacro.self),
        "RunInOrder": MacroSpec(type: RunInOrderMacro.self),
        "RunOnSingleDevice": MacroSpec(type: RunOnSingleDeviceMacro.self),
        "RunOnSingleMachine": MacroSpec(type: RunOnSingleMachineMacro.self),
        "Order": MacroSpec(type: OrderMacro.self),
        "RequiresDevice": MacroSpec(type: RequiresDeviceMacro.self),
        "ExcludesDevice": MacroSpec(type: ExcludesDeviceMacro.self),
    ]

    /// 期待する展開(クラス T・platform 無し)。entries は (メソッド名, 追加の欄の行)
    private func expected(entries: [(name: String, fields: [String])], placement: String? = nil) -> String {
        let members = entries.map { "    func \($0.name)() {\n    }" }.joined(separator: "\n")
        let descriptors = entries.map { entry -> String in
            let fields = entry.fields.map { "                \($0)\n" }.joined()
            return "            FTDSL.FTScenarioDescriptor(\n                name: \"\(entry.name)\",\n"
                + "                title: \"\",\n\(fields)"
                + "                run: {\n                    T().\(entry.name)()\n                }),"
        }.joined(separator: "\n")
        let tail = placement.map { ",\n            placement: .\($0)" } ?? ""
        return """
        class T {
        \(members)
        }

        final class __FTReg_T: FTDSL.FTScenarioRegistration {
            override class var descriptor: FTDSL.FTTestClassDescriptor {
                T.ftDescriptor
            }
        }

        extension T: FTDSL.FTTestClassDefinition {
            public static var ftDescriptor: FTDSL.FTTestClassDescriptor {
                FTDSL.FTTestClassDescriptor(
                    className: "T",
                    platform: nil,
                    scenarios: [
        \(descriptors)
                    ]\(tail))
            }
        }
        """
    }

    // MARK: 展開

    func testクラスだけの宣言は全シナリオへ載る() {
        let field = "deviceRequirements: .init(required: [.foldable, .minOS(platform: \"ios\", version: \"18\")], excluded: [.homeButton]),"
        assertMacroExpansion(
            """
            @TestClass
            @RequiresDevice(.foldable, .minOS(ios: "18"))
            @ExcludesDevice(.homeButton)
            class T {
                @Test
                func S0010() {
                }
                @Test
                func S0020() {
                }
            }
            """,
            expandedSource: expected(entries: [("S0010", [field]), ("S0020", [field])]),
            macroSpecs: macros)
    }

    func testテストだけの宣言はそのテストにだけ載る() {
        assertMacroExpansion(
            """
            @TestClass
            class T {
                @Test
                @RequiresDevice(.model("iPhone 18*"))
                func S0010() {
                }
                @Test
                func S0020() {
                }
            }
            """,
            expandedSource: expected(entries: [
                ("S0010", ["deviceRequirements: .init(required: [.model(\"iPhone 18*\")]),"]),
                ("S0020", []),
            ]),
            macroSpecs: macros)
    }

    func testクラスとテストは和を取り順序はクラスからテストで重複は先勝ち() {
        assertMacroExpansion(
            """
            @TestClass
            @RequiresDevice(.physical)
            @ExcludesDevice(.os("iOS 17*"))
            class T {
                @Test
                @RequiresDevice(.physical, .minOS(android: "15"))
                @ExcludesDevice(.virtual)
                func S0010() {
                }
            }
            """,
            expandedSource: expected(entries: [
                ("S0010", ["deviceRequirements: .init(required: [.physical, .minOS(platform: \"android\", version: \"15\")], "
                    + "excluded: [.os(\"iOS 17*\"), .virtual]),"]),
            ]),
            macroSpecs: macros)
    }

    func test宣言が無ければ欄を足さない() {
        assertMacroExpansion(
            """
            @TestClass
            class T {
                @Test
                func S0010() {
                }
            }
            """,
            expandedSource: expected(entries: [("S0010", [])]),
            macroSpecs: macros)
    }

    func test寄せ方の属性のクラスでもクラス側の宣言は通る() {
        assertMacroExpansion(
            """
            @TestClass
            @RunInOrder
            @RequiresDevice(.foldable)
            class T {
                @Test
                @Order(1)
                func S0010() {
                }
            }
            """,
            expandedSource: expected(entries: [
                ("S0010", ["order: 1,", "deviceRequirements: .init(required: [.foldable]),"]),
            ], placement: "inOrder"),
            macroSpecs: macros)
    }

    // MARK: コンパイルエラー

    private static let forms =
        ".foldable, .physical, .virtual, .homeButton, .minOS(ios: \"18\"), .minOS(android: \"15\"), .model(\"…\") or .os(\"…\")"

    func test変数と補間と呼び出しと別の綴りはリテラルでないとして断る() {
        let notLiteral = "@RequiresDevice takes only \(Self.forms), written directly"
            + " (no variables, string interpolation or escape sequences)"
        assertMacroExpansion(
            """
            @TestClass
            @RequiresDevice(cond)
            @RequiresDevice(.model("a\\(x)"))
            @RequiresDevice(.model(name()))
            @RequiresDevice(.minOS("18"))
            @RequiresDevice(.unknown)
            class T {
                @Test
                func S0010() {
                }
            }
            """,
            expandedSource: expected(entries: [("S0010", [])]),
            diagnostics: [
                DiagnosticSpec(message: notLiteral, line: 2, column: 17),
                DiagnosticSpec(message: notLiteral, line: 3, column: 17),
                DiagnosticSpec(message: notLiteral, line: 4, column: 17),
                DiagnosticSpec(message: notLiteral, line: 5, column: 17),
                DiagnosticSpec(message: notLiteral, line: 6, column: 17),
            ],
            macroSpecs: macros)
    }

    func test宣言の誤りは検査の文言つきで断る() {
        assertMacroExpansion(
            """
            @TestClass
            @RequiresDevice(.os("17*"))
            @ExcludesDevice(.minOS(ios: "18.x"))
            @RequiresDevice(.model("a||"))
            class T {
                @Test
                func S0010() {
                }
            }
            """,
            expandedSource: expected(entries: [("S0010", [])]),
            diagnostics: [
                DiagnosticSpec(
                    message: "@RequiresDevice .os(\"17*\"): os: alternative \"17*\" in \"17*\" must start with \"iOS \" or \"Android \"",
                    line: 2, column: 17),
                DiagnosticSpec(
                    message: "@ExcludesDevice .minOS(ios: \"18.x\"): minOS: version \"18.x\" must be dot-separated non-negative integers (e.g. \"18\" or \"17.4\")",
                    line: 3, column: 17),
                DiagnosticSpec(
                    message: "@RequiresDevice .model(\"a||\"): model: alternative 2 of 2 is empty (blank, or only invisible characters) in \"a||\"",
                    line: 4, column: 17),
            ],
            macroSpecs: macros)
    }

    func test引数の無い宣言は断る() {
        assertMacroExpansion(
            """
            @TestClass
            @RequiresDevice
            class T {
                @Test
                func S0010() {
                }
            }
            """,
            expandedSource: expected(entries: [("S0010", [])]),
            diagnostics: [
                DiagnosticSpec(message: "@RequiresDevice needs at least one condition: \(Self.forms)", line: 2, column: 1),
            ],
            macroSpecs: macros)
    }

    func test合併した宣言の矛盾は断る() {
        assertMacroExpansion(
            """
            @TestClass
            @RequiresDevice(.foldable, .physical)
            class T {
                @Test
                @ExcludesDevice(.foldable)
                @RequiresDevice(.virtual)
                func S0010() {
                }
            }
            """,
            expandedSource: expected(entries: [
                ("S0010", ["deviceRequirements: .init(required: [.foldable, .physical, .virtual], excluded: [.foldable]),"]),
            ]),
            diagnostics: [
                DiagnosticSpec(
                    message: "Device conditions of S0010 can never be satisfied: both physical and virtual are required;"
                        + " .foldable is both required and excluded",
                    line: 5, column: 5),
            ],
            macroSpecs: macros)
    }

    func test寄せ方の属性のクラスでテストに付けた宣言は断る() {
        for kind in ["RunInOrder", "RunOnSingleDevice", "RunOnSingleMachine"] {
            let isOrder = kind == "RunInOrder"
            let order = isOrder ? "\n    @Order(1)" : ""
            let placement = isOrder ? "inOrder" : kind == "RunOnSingleDevice" ? "singleDevice" : "singleMachine"
            assertMacroExpansion(
                """
                @TestClass
                @\(kind)
                class T {
                    @Test\(order)
                    @RequiresDevice(.foldable)
                    func S0010() {
                    }
                }
                """,
                expandedSource: expected(entries: [
                    ("S0010", (isOrder ? ["order: 1,"] : []) + ["deviceRequirements: .init(required: [.foldable]),"]),
                ], placement: placement),
                diagnostics: [
                    DiagnosticSpec(
                        message: "@\(kind) keeps the whole class together (one device or one machine), so a per-test device condition on S0010"
                            + " cannot be honoured separately: move it to the class (@RequiresDevice on the @TestClass class)"
                            + " or remove @\(kind)",
                        line: isOrder ? 6 : 5, column: 5),
                ],
                macroSpecs: macros)
        }
    }

    func test付け先の検査() {
        assertMacroExpansion(
            """
            @RequiresDevice(.foldable)
            class U {
            }
            """,
            expandedSource: "class U {\n}",
            diagnostics: [DiagnosticSpec(message: "@RequiresDevice requires @TestClass on the same class", line: 1, column: 1)],
            macroSpecs: macros)
    }
}
