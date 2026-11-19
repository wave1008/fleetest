import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest
@testable import FTDSLMacros

/// @RunOnSingleMachine / @RunOnSingleDevice / @RunInOrder / @Order(RR-8.3)の展開とコンパイルエラー
final class ClassPlacementMacroTests: XCTestCase {
    let macros: [String: MacroSpec] = [
        "TestClass": MacroSpec(type: TestClassMacro.self, conformances: ["FTDSL.FTTestClassDefinition"]),
        "Test": MacroSpec(type: TestMacro.self),
        "RunOnSingleMachine": MacroSpec(type: RunOnSingleMachineMacro.self),
        "RunOnSingleDevice": MacroSpec(type: RunOnSingleDeviceMacro.self),
        "RunInOrder": MacroSpec(type: RunInOrderMacro.self),
        "Order": MacroSpec(type: OrderMacro.self),
    ]

    private static let orderWithoutRunInOrder =
        "@Order has no effect without @RunInOrder on the class. Remove @Order: tests in a class run in no fixed order"
        + " and should not depend on each other; if steps must run in order, put them in one @Test."
        + " Only if that is not possible, add @RunInOrder to the class (it gives up parallel execution, stops the"
        + " remaining tests after the first failure, and reruns failed tests from the first test of the class)"

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

    // MARK: 正常系

    func testRunInOrderはplacementとorderを生成コードへ載せる() {
        assertMacroExpansion(
            """
            @TestClass
            @RunInOrder
            class T {
                @Test
                @Order(2)
                func S0020() {
                }
                @Test
                @Order(1)
                func S0010() {
                }
            }
            """,
            expandedSource: expected(entries: [("S0020", ["order: 2,"]), ("S0010", ["order: 1,"])],
                                     placement: "inOrder"),
            macroSpecs: macros)
    }

    func testRunOnSingleMachineはplacementだけ載せorderは載せない() {
        assertMacroExpansion(
            """
            @TestClass
            @RunOnSingleMachine("shared DB")
            class T {
                @Test
                func S0010() {
                }
            }
            """,
            expandedSource: expected(entries: [("S0010", [])], placement: "singleMachine"),
            macroSpecs: macros)
    }

    func testRunOnSingleDeviceはplacementを載せる() {
        assertMacroExpansion(
            """
            @TestClass
            @RunOnSingleDevice
            class T {
                @Test
                func S0010() {
                }
            }
            """,
            expandedSource: expected(entries: [("S0010", [])], placement: "singleDevice"),
            macroSpecs: macros)
    }

    func test属性が無ければ生成コードに欄を足さない() {
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

    func testOrderの値が整数リテラルでなければエラー() {
        assertMacroExpansion(
            """
            @TestClass
            @RunInOrder
            class T {
                @Test
                @Order(first)
                func S0010() {
                }
                @Test
                @Order(first)
                func S0020() {
                }
            }
            """,
            expandedSource: expected(entries: [("S0010", ["order: first,"]), ("S0020", ["order: first,"])],
                                     placement: "inOrder"),
            diagnostics: [
                DiagnosticSpec(message: Self.orderNotLiteral, line: 5, column: 12),
                DiagnosticSpec(message: Self.orderNotLiteral, line: 9, column: 12),
            ],
            macroSpecs: macros)
    }

    private static let orderNotLiteral =
        "@Order needs an integer written directly, such as @Order(10), so that duplicate values can be found at compile time"

    func testOrderの値は負の数と区切りの入った整数も受け付ける() {
        assertMacroExpansion(
            """
            @TestClass
            @RunInOrder
            class T {
                @Test
                @Order(-1)
                func S0010() {
                }
                @Test
                @Order(1_000)
                func S0020() {
                }
            }
            """,
            expandedSource: expected(entries: [("S0010", ["order: -1,"]), ("S0020", ["order: 1_000,"])],
                                     placement: "inOrder"),
            macroSpecs: macros)
    }

    func test機械に寄せる属性はOSが混ざっていてもエラーにしない() {
        assertMacroExpansion(
            """
            @TestClass
            @RunOnSingleMachine
            class T {
                @Test(platform: "ios")
                func S0010() {
                }
                @Test
                func S0020() {
                }
            }
            """,
            expandedSource: expected(entries: [("S0010", ["platform: \"ios\","]), ("S0020", [])],
                                     placement: "singleMachine"),
            macroSpecs: macros)
    }

    // MARK: コンパイルエラー(@TestClass 側)

    func test2つ以上の属性の同時付与はエラー() {
        assertMacroExpansion(
            """
            @TestClass
            @RunOnSingleMachine
            @RunInOrder
            class T {
                @Test
                func S0010() {
                }
            }
            """,
            expandedSource: expected(entries: [("S0010", [])], placement: "singleMachine"),
            diagnostics: [
                DiagnosticSpec(
                    message: "A test class can have only one of @RunOnSingleMachine, @RunOnSingleDevice, @RunInOrder"
                        + " (found @RunOnSingleMachine and @RunInOrder)",
                    line: 3, column: 1),
            ],
            macroSpecs: macros)
    }

    func test3つ全部の同時付与は後ろの2つを診断する() {
        assertMacroExpansion(
            """
            @TestClass
            @RunOnSingleDevice
            @RunOnSingleMachine
            @RunInOrder
            class T {
                @Test
                func S0010() {
                }
            }
            """,
            expandedSource: expected(entries: [("S0010", [])], placement: "singleDevice"),
            diagnostics: [
                DiagnosticSpec(
                    message: "A test class can have only one of @RunOnSingleMachine, @RunOnSingleDevice, @RunInOrder"
                        + " (found @RunOnSingleDevice and @RunOnSingleMachine and @RunInOrder)",
                    line: 3, column: 1),
                DiagnosticSpec(
                    message: "A test class can have only one of @RunOnSingleMachine, @RunOnSingleDevice, @RunInOrder"
                        + " (found @RunOnSingleDevice and @RunOnSingleMachine and @RunInOrder)",
                    line: 4, column: 1),
            ],
            macroSpecs: macros)
    }

    func testRunInOrderの無いクラスのOrderはエラーで失うものを言う() {
        assertMacroExpansion(
            """
            @TestClass
            class T {
                @Test
                @Order(1)
                func S0010() {
                }
            }
            """,
            expandedSource: expected(entries: [("S0010", [])]),
            diagnostics: [
                DiagnosticSpec(message: Self.orderWithoutRunInOrder, line: 4, column: 12),
            ],
            macroSpecs: macros)
    }

    func test他の寄せ方のクラスのOrderもエラー() {
        assertMacroExpansion(
            """
            @TestClass
            @RunOnSingleDevice
            class T {
                @Test
                @Order(1)
                func S0010() {
                }
            }
            """,
            expandedSource: expected(entries: [("S0010", [])], placement: "singleDevice"),
            diagnostics: [
                DiagnosticSpec(message: Self.orderWithoutRunInOrder, line: 5, column: 12),
            ],
            macroSpecs: macros)
    }

    func testRunInOrderのクラスでOrderの無いTestはエラー() {
        assertMacroExpansion(
            """
            @TestClass
            @RunInOrder
            class T {
                @Test
                @Order(1)
                func S0010() {
                }
                @Test
                func S0020() {
                }
            }
            """,
            expandedSource: expected(entries: [("S0010", ["order: 1,"]), ("S0020", [])], placement: "inOrder"),
            diagnostics: [
                DiagnosticSpec(message: "@Test S0020 needs @Order(n) because the class is @RunInOrder",
                               line: 9, column: 10),
            ],
            macroSpecs: macros)
    }

    func testOrderの値の重複はエラー() {
        assertMacroExpansion(
            """
            @TestClass
            @RunInOrder
            class T {
                @Test
                @Order(1)
                func S0010() {
                }
                @Test
                @Order(1)
                func S0020() {
                }
            }
            """,
            expandedSource: expected(entries: [("S0010", ["order: 1,"]), ("S0020", ["order: 1,"])],
                                     placement: "inOrder"),
            diagnostics: [
                DiagnosticSpec(message: "@Order(1) is used twice in this @RunInOrder class (S0010 and S0020)",
                               line: 9, column: 12),
            ],
            macroSpecs: macros)
    }

    func testデバイスに寄せる属性でOSの宣言がそろっていないとエラー() {
        assertMacroExpansion(
            """
            @TestClass
            @RunOnSingleDevice
            class T {
                @Test(platform: "ios")
                func S0010() {
                }
                @Test
                func S0020() {
                }
            }
            """,
            expandedSource: expected(entries: [("S0010", ["platform: \"ios\","]), ("S0020", [])],
                                     placement: "singleDevice"),
            diagnostics: [
                DiagnosticSpec(
                    message: "@RunOnSingleDevice needs every @Test to run on the same OS, but the effective platforms"
                        + " differ (\"ios\", nil): declare platform: on @TestClass (or on every @Test) so they all match",
                    line: 2, column: 1),
            ],
            macroSpecs: macros)
    }

    func testPlatformにnilを明示しても未宣言と同じでエラーにしない() {
        assertMacroExpansion(
            """
            @TestClass
            @RunOnSingleDevice
            class T {
                @Test(platform: nil)
                func S0010() {
                }
                @Test
                func S0020() {
                }
            }
            """,
            expandedSource: expected(entries: [("S0010", ["platform: nil,"]), ("S0020", [])],
                                     placement: "singleDevice"),
            macroSpecs: macros)
    }

    func testRunInOrderでiosとandroidが混ざるとエラー() {
        assertMacroExpansion(
            """
            @TestClass
            @RunInOrder
            class T {
                @Test(platform: "ios")
                @Order(1)
                func S0010() {
                }
                @Test(platform: "android")
                @Order(2)
                func S0020() {
                }
            }
            """,
            expandedSource: expected(entries: [("S0010", ["platform: \"ios\",", "order: 1,"]),
                                               ("S0020", ["platform: \"android\",", "order: 2,"])],
                                     placement: "inOrder"),
            diagnostics: [
                DiagnosticSpec(
                    message: "@RunInOrder needs every @Test to run on the same OS, but the effective platforms"
                        + " differ (\"android\", \"ios\"): declare platform: on @TestClass (or on every @Test) so they all match",
                    line: 2, column: 1),
            ],
            macroSpecs: macros)
    }

    // MARK: コンパイルエラー(印の側)

    func test寄せる属性を食わせた先がTestClassの無いクラスだとエラー() {
        assertMacroExpansion(
            """
            @RunInOrder
            class T {
            }
            """,
            expandedSource: "class T {\n}",
            diagnostics: [
                DiagnosticSpec(message: "@RunInOrder requires @TestClass on the same class", line: 1, column: 1),
            ],
            macroSpecs: macros)
    }

    func test寄せる属性をクラス以外へ付けるとエラー() {
        assertMacroExpansion(
            """
            @RunOnSingleMachine
            struct T {
            }
            """,
            expandedSource: "struct T {\n}",
            diagnostics: [
                DiagnosticSpec(message: "@RunOnSingleMachine can only be attached to a @TestClass class",
                               line: 1, column: 1),
            ],
            macroSpecs: macros)
    }

    func testOrderをTestの無い関数へ付けるとエラー() {
        assertMacroExpansion(
            """
            class T {
                @Order(1)
                func helper() {
                }
            }
            """,
            expandedSource: "class T {\n    func helper() {\n    }\n}",
            diagnostics: [
                DiagnosticSpec(message: "@Order requires @Test on the same method", line: 2, column: 5),
            ],
            macroSpecs: macros)
    }

    func testOrderを関数以外へ付けるとエラー() {
        assertMacroExpansion(
            """
            @Order(1)
            var x = 1
            """,
            expandedSource: "var x = 1",
            diagnostics: [
                DiagnosticSpec(message: "@Order can only be attached to a @Test method", line: 1, column: 1),
            ],
            macroSpecs: macros)
    }

    // MARK: @Test を囲む型に @TestClass が無い

    private static let testWithoutTestClass =
        "@Test requires the enclosing class to have @TestClass; without it this test is silently left out"
        + " of the scenario list. Add @TestClass to the class"

    func testTestClassの無いクラスのTestはエラー() {
        assertMacroExpansion(
            """
            class T {
                @Test
                func S0010() {
                }
            }
            """,
            expandedSource: "class T {\n    func S0010() {\n    }\n}",
            diagnostics: [
                DiagnosticSpec(message: Self.testWithoutTestClass, line: 2, column: 5),
            ],
            macroSpecs: macros)
    }

    func testTestClassのあるクラスのTestはエラーにしない() {
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

    func testクラス以外の型の中のTestもエラー() {
        assertMacroExpansion(
            """
            struct T {
                @Test
                func S0010() {
                }
            }
            """,
            expandedSource: "struct T {\n    func S0010() {\n    }\n}",
            diagnostics: [
                DiagnosticSpec(message: Self.testWithoutTestClass, line: 2, column: 5),
            ],
            macroSpecs: macros)
    }

    func testextensionの中のTestは拡張先が見えないので通す() {
        assertMacroExpansion(
            """
            extension T {
                @Test
                func S0010() {
                }
            }
            """,
            expandedSource: "extension T {\n    func S0010() {\n    }\n}",
            macroSpecs: macros)
    }
}
