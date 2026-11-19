// @RunOnSingleMachine / @RunOnSingleDevice / @RunInOrder / @Order(RR-8.3・DR-206)。
// 4つとも何も生成しない印で、@TestClass の extension ロールが読む(診断も extension ロールの1箇所で出す)。
// ClassPlacementKind の rawValue は FTCore.ClassPlacement の case 名と一致させる(生成コードが `.<rawValue>` と書く)。

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

enum ClassPlacementKind: String, CaseIterable {
    case singleMachine, singleDevice, inOrder

    var attributeName: String {
        switch self {
        case .singleMachine: return "RunOnSingleMachine"
        case .singleDevice: return "RunOnSingleDevice"
        case .inOrder: return "RunInOrder"
        }
    }

    var bindsDevice: Bool { self != .singleMachine }
}

extension TestClassMacro {

    static func attribute(named name: String, in attributes: AttributeListSyntax) -> AttributeSyntax? {
        for attr in attributes {
            guard let syntax = attr.as(AttributeSyntax.self) else { continue }
            let written = syntax.attributeName.trimmedDescription
            if written == name || written.hasSuffix(".\(name)") { return syntax }
        }
        return nil
    }

    /// クラスの属性リストに @TestClass(FTDSL.TestClass も可)が含まれるか
    static func hasTestClass(_ attributes: AttributeListSyntax) -> Bool {
        attribute(named: "TestClass", in: attributes) != nil
    }

    /// 寄せ方の属性と @Order の検査。診断はここだけで出す。付いている寄せ方(複数なら先頭)を返す
    static func diagnoseClassPlacement(_ cls: ClassDeclSyntax,
                                       methods: [ScenarioMethod],
                                       classPlatformExpr: String,
                                       context: some MacroExpansionContext) -> ClassPlacementKind? {
        // ソース上の並びで拾う(同時付与のとき、先に書いたほうを採り、後ろを診断する)
        let present: [(kind: ClassPlacementKind, node: AttributeSyntax)] = cls.attributes.compactMap { attr in
            guard let syntax = attr.as(AttributeSyntax.self) else { return nil }
            let written = syntax.attributeName.trimmedDescription
            guard let kind = ClassPlacementKind.allCases.first(where: {
                written == $0.attributeName || written.hasSuffix(".\($0.attributeName)")
            }) else { return nil }
            return (kind: kind, node: syntax)
        }
        let allNames = ClassPlacementKind.allCases.map { "@\($0.attributeName)" }
        if present.count >= 2 {
            let names = present.map { "@\($0.kind.attributeName)" }.joined(separator: " and ")
            for extra in present.dropFirst() {
                context.diagnose(Diagnostic(
                    node: Syntax(extra.node),
                    message: FTDSLDiagnostic(
                        "A test class can have only one of \(allNames.joined(separator: ", ")) (found \(names))",
                        id: "placement-conflict")))
            }
        }
        let placement = present.first?.kind

        let orderedMethods = methods.filter { $0.orderExpr != nil }
        if placement != .inOrder {
            for method in orderedMethods {
                context.diagnose(Diagnostic(
                    node: method.orderNode.map { Syntax($0) } ?? method.nameNode,
                    message: FTDSLDiagnostic(
                        "@Order has no effect without @RunInOrder on the class. Remove @Order: tests in a class run in no fixed order"
                            + " and should not depend on each other; if steps must run in order, put them in one @Test."
                            + " Only if that is not possible, add @RunInOrder to the class (it gives up parallel execution, stops the"
                            + " remaining tests after the first failure, and reruns failed tests from the first test of the class)",
                        id: "order-without-run-in-order")))
            }
        }
        if placement == .inOrder {
            var seen: [Int: String] = [:]
            for method in methods {
                guard let expr = method.orderExpr, let node = method.orderNode else {
                    context.diagnose(Diagnostic(
                        node: method.nameNode,
                        message: FTDSLDiagnostic(
                            "@Test \(method.name) needs @Order(n) because the class is @RunInOrder",
                            id: "missing-order")))
                    continue
                }
                guard let value = integerLiteralValue(node) else { continue }
                if let first = seen[value] {
                    context.diagnose(Diagnostic(
                        node: Syntax(node),
                        message: FTDSLDiagnostic(
                            "@Order(\(expr)) is used twice in this @RunInOrder class (\(first) and \(method.name))",
                            id: "duplicate-order")))
                } else {
                    seen[value] = method.name
                }
            }
        }

        if let placement, placement.bindsDevice, let node = present.first(where: { $0.kind == placement })?.node {
            // `@Test(platform: nil)` は書かないのと同じ(クラスの宣言に従う = FTScenarioDescriptor.effectivePlatform)
            let platforms = Set(methods.map { m in m.platformExpr.flatMap { $0 == "nil" ? nil : $0 } ?? classPlatformExpr })
            if platforms.count >= 2 {
                context.diagnose(Diagnostic(
                    node: Syntax(node),
                    message: FTDSLDiagnostic(
                        "@\(placement.attributeName) needs every @Test to run on the same OS, but the effective platforms differ"
                            + " (\(platforms.sorted().joined(separator: ", "))): declare platform: on @TestClass (or on every @Test)"
                            + " so they all match",
                        id: "placement-platform-mismatch")))
            }
        }
        return placement
    }

    /// 寄せ方の属性のマーカー検査(クラスにだけ・@TestClass のあるクラスにだけ付ける)
    static func diagnosePlacementTarget(_ name: String, node: AttributeSyntax,
                                        declaration: some DeclSyntaxProtocol,
                                        context: some MacroExpansionContext) {
        guard let cls = declaration.as(ClassDeclSyntax.self) else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: FTDSLDiagnostic("@\(name) can only be attached to a @TestClass class", id: "placement-target")))
            return
        }
        if !hasTestClass(cls.attributes) {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: FTDSLDiagnostic("@\(name) requires @TestClass on the same class", id: "placement-without-test-class")))
        }
    }
}

public struct RunOnSingleMachineMacro: PeerMacro {
    public static func expansion(of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol,
                                 in context: some MacroExpansionContext) throws -> [DeclSyntax] {
        TestClassMacro.diagnosePlacementTarget("RunOnSingleMachine", node: node, declaration: declaration, context: context)
        return []
    }
}

public struct RunOnSingleDeviceMacro: PeerMacro {
    public static func expansion(of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol,
                                 in context: some MacroExpansionContext) throws -> [DeclSyntax] {
        TestClassMacro.diagnosePlacementTarget("RunOnSingleDevice", node: node, declaration: declaration, context: context)
        return []
    }
}

public struct RunInOrderMacro: PeerMacro {
    public static func expansion(of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol,
                                 in context: some MacroExpansionContext) throws -> [DeclSyntax] {
        TestClassMacro.diagnosePlacementTarget("RunInOrder", node: node, declaration: declaration, context: context)
        return []
    }
}

public struct OrderMacro: PeerMacro {
    public static func expansion(of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol,
                                 in context: some MacroExpansionContext) throws -> [DeclSyntax] {
        guard let fn = declaration.as(FunctionDeclSyntax.self) else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: FTDSLDiagnostic("@Order can only be attached to a @Test method", id: "order-target")))
            return []
        }
        if TestClassMacro.attribute(named: "Test", in: fn.attributes) == nil {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: FTDSLDiagnostic("@Order requires @Test on the same method", id: "order-without-test")))
        }
        return []
    }
}
