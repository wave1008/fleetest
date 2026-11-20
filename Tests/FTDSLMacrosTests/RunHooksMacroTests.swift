import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest
@testable import FTDSLMacros

/// @RunHooks(RR-8.4・DR-209)の展開とコンパイルエラー
final class RunHooksMacroTests: XCTestCase {
    let macros: [String: MacroSpec] = [
        "RunHooks": MacroSpec(type: RunHooksMacro.self, conformances: ["FTDSL.FTRunHooksDefinition"]),
    ]

    func testBeforeRunとafterRunの両方がdescriptorの欄になる() {
        assertMacroExpansion(
            """
            @RunHooks
            class T {
                func beforeRun() {
                }
                func afterRun() {
                }
            }
            """,
            expandedSource:
            """
            class T {
                func beforeRun() {
                }
                func afterRun() {
                }
            }

            final class __FTRunHooksReg_T: FTDSL.FTRunHooksRegistration {
                override class var descriptor: FTDSL.FTRunHooksDescriptor {
                    T.ftRunHooksDescriptor
                }
            }

            extension T: FTDSL.FTRunHooksDefinition {
                public static var ftRunHooksDescriptor: FTDSL.FTRunHooksDescriptor {
                    FTDSL.FTRunHooksDescriptor(
                        className: "T",
                        beforeRun: {
                            let ftInstance = T();
                            FTDSL.ftRunBeforeRun {
                                ftInstance.beforeRun()
                            }
                        },
                        afterRun: {
                            let ftInstance = T();
                            FTDSL.ftRunAfterRun {
                                ftInstance.afterRun()
                            }
                        })
                }
            }
            """,
            macroSpecs: macros)
    }

    func test片方だけでもよく無い方の欄は生成しない() {
        assertMacroExpansion(
            """
            @RunHooks
            class T {
                func afterRun() {
                }
            }
            """,
            expandedSource:
            """
            class T {
                func afterRun() {
                }
            }

            final class __FTRunHooksReg_T: FTDSL.FTRunHooksRegistration {
                override class var descriptor: FTDSL.FTRunHooksDescriptor {
                    T.ftRunHooksDescriptor
                }
            }

            extension T: FTDSL.FTRunHooksDefinition {
                public static var ftRunHooksDescriptor: FTDSL.FTRunHooksDescriptor {
                    FTDSL.FTRunHooksDescriptor(
                        className: "T",
                        afterRun: {
                            let ftInstance = T();
                            FTDSL.ftRunAfterRun {
                                ftInstance.afterRun()
                            }
                        })
                }
            }
            """,
            macroSpecs: macros)
    }

    func testTestClassと同じクラスに付けるとコンパイルエラー() {
        assertMacroExpansion(
            """
            @RunHooks
            @TestClass
            class T {
                func beforeRun() {
                }
            }
            """,
            expandedSource:
            """
            @TestClass
            class T {
                func beforeRun() {
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@RunHooks cannot be attached to a @TestClass class: put beforeRun() / afterRun() in a"
                        + " separate class that has only @RunHooks",
                    line: 1, column: 1),
            ],
            macroSpecs: macros)
    }

    func test引数や非同期のフックはコンパイルエラーで名指しする() {
        assertMacroExpansion(
            """
            @RunHooks
            class T {
                func beforeRun() {
                }
                func afterRun() async {
                }
            }
            """,
            expandedSource:
            """
            class T {
                func beforeRun() {
                }
                func afterRun() async {
                }
            }

            final class __FTRunHooksReg_T: FTDSL.FTRunHooksRegistration {
                override class var descriptor: FTDSL.FTRunHooksDescriptor {
                    T.ftRunHooksDescriptor
                }
            }

            extension T: FTDSL.FTRunHooksDefinition {
                public static var ftRunHooksDescriptor: FTDSL.FTRunHooksDescriptor {
                    FTDSL.FTRunHooksDescriptor(
                        className: "T",
                        beforeRun: {
                            let ftInstance = T();
                            FTDSL.ftRunBeforeRun {
                                ftInstance.beforeRun()
                            }
                        })
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@RunHooks methods must take no arguments and be neither async nor throws: func afterRun()",
                    line: 5, column: 10),
            ],
            macroSpecs: macros)
    }

    func testどちらも書かれていなければ警告() {
        assertMacroExpansion(
            """
            @RunHooks
            class T {
            }
            """,
            expandedSource:
            """
            class T {
            }

            final class __FTRunHooksReg_T: FTDSL.FTRunHooksRegistration {
                override class var descriptor: FTDSL.FTRunHooksDescriptor {
                    T.ftRunHooksDescriptor
                }
            }

            extension T: FTDSL.FTRunHooksDefinition {
                public static var ftRunHooksDescriptor: FTDSL.FTRunHooksDescriptor {
                    FTDSL.FTRunHooksDescriptor(
                        className: "T")
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@RunHooks class T has neither beforeRun() nor afterRun(), so nothing runs",
                    line: 1, column: 1, severity: .warning),
            ],
            macroSpecs: macros)
    }

    func testクラス以外に付けるとコンパイルエラー() {
        assertMacroExpansion(
            """
            @RunHooks
            struct S {
            }
            """,
            expandedSource:
            """
            struct S {
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@RunHooks can only be attached to a class", line: 1, column: 1),
            ],
            macroSpecs: macros)
    }
}
