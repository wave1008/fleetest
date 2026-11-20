// @RunHooks(RR-8.4・DR-209)の実装。
// - extension ロール: FTRunHooksDefinition conformance と ftRunHooksDescriptor(beforeRun / afterRun)を生成
// - peer ロール: objc ランタイム発見用の登録クラス __FTRunHooksReg_<クラス名> を生成
// 診断は extension ロールの1箇所だけで出す(peer でも出すと同じ診断が2回出る)。
// 「プロジェクトに2つ以上」はマクロからは見えないので、一覧の段(`list --json` の runHooks)で数える。

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct RunHooksMacro {
    static let hookNames = ["beforeRun", "afterRun"]

    /// 名前が beforeRun / afterRun なのに「引数なし・非async・非throws」でないメソッドは、黙って登録から落ちるので名指しする
    static func diagnoseHookSignatures(in declaration: some DeclGroupSyntax,
                                       context: some MacroExpansionContext) {
        for member in declaration.memberBlock.members {
            guard let fn = member.decl.as(FunctionDeclSyntax.self), hookNames.contains(fn.name.text) else { continue }
            let signature = fn.signature
            if !signature.parameterClause.parameters.isEmpty || signature.effectSpecifiers != nil {
                context.diagnose(Diagnostic(
                    node: Syntax(fn.name),
                    message: FTDSLDiagnostic(
                        "@RunHooks methods must take no arguments and be neither async nor throws: func \(fn.name.text)()",
                        id: "run-hook-signature")))
            }
        }
    }
}

extension RunHooksMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let cls = declaration.as(ClassDeclSyntax.self) else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: FTDSLDiagnostic("@RunHooks can only be attached to a class", id: "run-hooks-not-a-class")))
            return []
        }
        if TestClassMacro.hasTestClass(cls.attributes) {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: FTDSLDiagnostic(
                    "@RunHooks cannot be attached to a @TestClass class: put beforeRun() / afterRun() in a separate"
                        + " class that has only @RunHooks",
                    id: "run-hooks-with-test-class")))
            return []
        }
        diagnoseHookSignatures(in: declaration, context: context)
        guard !protocols.isEmpty else { return [] }

        let className = cls.name.text
        let hasBefore = TestClassMacro.hasLifecycleMethod("beforeRun", in: declaration)
        let hasAfter = TestClassMacro.hasLifecycleMethod("afterRun", in: declaration)
        if !hasBefore, !hasAfter {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: FTDSLDiagnostic(
                    "@RunHooks class \(className) has neither beforeRun() nor afterRun(), so nothing runs",
                    id: "run-hooks-empty", severity: .warning)))
        }
        var arguments = ["className: \(TestClassMacro.literalString(className))"]
        if hasBefore {
            arguments.append("beforeRun: { let ftInstance = \(className)(); "
                + "FTDSL.ftRunBeforeRun { ftInstance.beforeRun() } }")
        }
        if hasAfter {
            arguments.append("afterRun: { let ftInstance = \(className)(); "
                + "FTDSL.ftRunAfterRun { ftInstance.afterRun() } }")
        }
        let ext = try ExtensionDeclSyntax(
            """
            extension \(type.trimmed): FTDSL.FTRunHooksDefinition {
                public static var ftRunHooksDescriptor: FTDSL.FTRunHooksDescriptor {
                    FTDSL.FTRunHooksDescriptor(
                        \(raw: arguments.joined(separator: ",\n            ")))
                }
            }
            """)
        return [ext]
    }
}

extension RunHooksMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let cls = declaration.as(ClassDeclSyntax.self),
              !TestClassMacro.hasTestClass(cls.attributes) else { return [] }
        let className = cls.name.text
        let reg: DeclSyntax =
            """
            final class __FTRunHooksReg_\(raw: className): FTDSL.FTRunHooksRegistration {
                override class var descriptor: FTDSL.FTRunHooksDescriptor { \(raw: className).ftRunHooksDescriptor }
            }
            """
        return [reg]
    }
}
