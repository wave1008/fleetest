// @RequiresDevice / @ExcludesDevice(DR-237)。マーカーで、@TestClass の extension ロールがクラスと各 @Test の宣言を読み、
// 合わせた条件の組をシナリオごとの descriptor に載せる(診断も extension ロールの1箇所)。
// マクロターゲットは FTCore に依存できないので、宣言の検査は FTCore.DeviceCondition.declarationError / DeviceRequirementSet.contradictions の
// 写し。**正本は FTCore 側**で、文言まで `DeviceRequirementMacroPinTests` が同じ表で突き合わせる(変えるなら両方)。

import Foundation
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// FTCore.DeviceCondition の写し(綴りは `described` と同一)
enum DeviceConditionSpec: Equatable {
    case foldable, physical, virtual, homeButton
    case minOS(platform: String, version: String)
    case model(String)
    case os(String)

    var described: String {
        switch self {
        case .foldable: return ".foldable"
        case .physical: return ".physical"
        case .virtual: return ".virtual"
        case .homeButton: return ".homeButton"
        case .minOS(let platform, let version): return ".minOS(\(platform): \"\(version)\")"
        case .model(let p): return ".model(\"\(p)\")"
        case .os(let p): return ".os(\"\(p)\")"
        }
    }

    /// 生成コード(FTCore.DeviceCondition のリテラル)
    var emitted: String {
        switch self {
        case .minOS(let platform, let version):
            return ".minOS(platform: \(TestClassMacro.literalString(platform)), version: \(TestClassMacro.literalString(version)))"
        case .model(let p): return ".model(\(TestClassMacro.literalString(p)))"
        case .os(let p): return ".os(\(TestClassMacro.literalString(p)))"
        default: return described
        }
    }

    private static let osPrefixes: [(platform: String, prefix: String)] = [("ios", "iOS "), ("android", "Android ")]

    /// FTCore.DeviceCondition.declarationError の写し(文言も同一)
    var declarationError: String? {
        switch self {
        case .foldable, .physical, .virtual, .homeButton:
            return nil
        case .minOS(let platform, let version):
            guard Self.osPrefixes.contains(where: { $0.platform == platform }) else {
                return "minOS: platform \"\(platform)\" must be \"ios\" or \"android\""
            }
            guard Self.versionIsValid(version) else {
                return "minOS: version \"\(version)\" must be dot-separated non-negative integers (e.g. \"18\" or \"17.4\")"
            }
            return nil
        case .model(let pattern):
            return Self.patternError(pattern, argument: "model")
        case .os(let pattern):
            if let error = Self.patternError(pattern, argument: "os") { return error }
            for branch in Self.alternatives(pattern)
            where !Self.osPrefixes.contains(where: { branch.hasPrefix($0.prefix) }) {
                return "os: alternative \"\(branch)\" in \"\(pattern)\" must start with \"iOS \" or \"Android \""
            }
            return nil
        }
    }

    static func versionIsValid(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    private static func alternatives(_ pattern: String) -> [String] {
        pattern.components(separatedBy: "||")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 単独で立つと見えない文字(FTCore の TextNormalization.isInvisibleScalar の写し)
    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        guard !scalar.properties.isWhitespace else { return false }
        let category = scalar.properties.generalCategory
        return category == .format || category == .control || scalar.properties.isDefaultIgnorableCodePoint
    }

    /// FTCore.ValuePattern.patternError の写し。見えない文字の落とし方は TextNormalization.text より粗い
    /// (クラスタ単位でなくスカラ単位)ので、空になるかの判定が一致する範囲だけを写す(表で固定)
    private static func patternError(_ pattern: String, argument: String) -> String? {
        let branches = pattern.components(separatedBy: "||")
        for (offset, raw) in branches.enumerated() {
            let branch = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            func blank<S: Sequence>(_ scalars: S) -> Bool where S.Element == Unicode.Scalar {
                scalars.allSatisfy { isInvisible($0) || $0.properties.isWhitespace || $0.properties.generalCategory.isSeparator }
            }
            if blank(branch.unicodeScalars) {
                return "\(argument): alternative \(offset + 1) of \(branches.count) is empty (blank, or only invisible characters) in \"\(pattern)\""
            }
            // FTSelector.partialMatch の4形の text 部分
            var text = Substring(branch)
            let lead = branch.hasPrefix("*"), trail = branch.hasSuffix("*")
            if lead, trail, branch.count >= 3 { text = text.dropFirst().dropLast() }
            else if trail, branch.count >= 2 { text = text.dropLast() }
            else if lead, branch.count >= 2 { text = text.dropFirst() }
            if blank(text.unicodeScalars) {
                return "\(argument): alternative \"\(branch)\" has no text besides `*` and invisible characters — it would match any \(argument)"
            }
        }
        return nil
    }
}

private extension Unicode.GeneralCategory {
    var isSeparator: Bool { self == .spaceSeparator || self == .lineSeparator || self == .paragraphSeparator }
}

/// 属性1組(クラスまたはテストメソッド)の宣言
struct DeviceDeclaration {
    var required: [DeviceConditionSpec] = []
    var excluded: [DeviceConditionSpec] = []
    /// 診断位置(最初の @RequiresDevice / @ExcludesDevice)
    var firstNode: AttributeSyntax?

    var isEmpty: Bool { required.isEmpty && excluded.isEmpty }
}

extension TestClassMacro {
    static let requiresName = "RequiresDevice"
    static let excludesName = "ExcludesDevice"

    private static let conditionForms =
        ".foldable, .physical, .virtual, .homeButton, .minOS(ios: \"18\"), .minOS(android: \"15\"), .model(\"…\") or .os(\"…\")"

    /// 属性リストの @RequiresDevice / @ExcludesDevice を読む。書式の診断(リテラルでない・空・宣言の誤り)はここで出す
    static func parseDeviceDeclaration(_ attributes: AttributeListSyntax,
                                       context: some MacroExpansionContext) -> DeviceDeclaration {
        var decl = DeviceDeclaration()
        for attr in attributes {
            guard let syntax = attr.as(AttributeSyntax.self) else { continue }
            let written = syntax.attributeName.trimmedDescription
            let isRequires = written == requiresName || written.hasSuffix(".\(requiresName)")
            let isExcludes = written == excludesName || written.hasSuffix(".\(excludesName)")
            guard isRequires || isExcludes else { continue }
            let name = isRequires ? requiresName : excludesName
            if decl.firstNode == nil { decl.firstNode = syntax }
            let args = syntax.arguments?.as(LabeledExprListSyntax.self)
            guard let args, !args.isEmpty else {
                context.diagnose(Diagnostic(
                    node: Syntax(syntax),
                    message: FTDSLDiagnostic("@\(name) needs at least one condition: \(conditionForms)",
                                             id: "device-condition-empty")))
                continue
            }
            for arg in args {
                guard arg.label == nil, let spec = parseDeviceCondition(arg.expression) else {
                    context.diagnose(Diagnostic(
                        node: Syntax(arg.expression),
                        message: FTDSLDiagnostic(
                            "@\(name) takes only \(conditionForms), written directly"
                                + " (no variables, string interpolation or escape sequences)",
                            id: "device-condition-not-literal")))
                    continue
                }
                if let error = spec.declarationError {
                    context.diagnose(Diagnostic(
                        node: Syntax(arg.expression),
                        message: FTDSLDiagnostic("@\(name) \(spec.described): \(error)", id: "device-condition-invalid")))
                    continue
                }
                if isRequires { decl.required.append(spec) } else { decl.excluded.append(spec) }
            }
        }
        return decl
    }

    private static func parseDeviceCondition(_ expr: ExprSyntax) -> DeviceConditionSpec? {
        if let member = expr.as(MemberAccessExprSyntax.self), member.base == nil {
            switch member.declName.baseName.text {
            case "foldable": return .foldable
            case "physical": return .physical
            case "virtual": return .virtual
            case "homeButton": return .homeButton
            default: return nil
            }
        }
        guard let call = expr.as(FunctionCallExprSyntax.self),
              let callee = call.calledExpression.as(MemberAccessExprSyntax.self), callee.base == nil,
              call.arguments.count == 1, let arg = call.arguments.first,
              call.trailingClosure == nil, call.additionalTrailingClosures.isEmpty,
              let value = plainStringValue(arg.expression) else { return nil }
        switch (callee.declName.baseName.text, arg.label?.text) {
        case ("minOS", "ios"): return .minOS(platform: "ios", version: value)
        case ("minOS", "android"): return .minOS(platform: "android", version: value)
        case ("model", nil): return .model(value)
        case ("os", nil): return .os(value)
        default: return nil
        }
    }

    /// 補間・エスケープ・raw・複数行の無い素の文字列リテラルだけ(宣言の検査をコンパイル時に確定させるため)
    private static func plainStringValue(_ expr: ExprSyntax) -> String? {
        guard let lit = expr.as(StringLiteralExprSyntax.self),
              lit.openingPounds == nil, lit.openingQuote.tokenKind == .stringQuote else { return nil }
        var out = ""
        for seg in lit.segments {
            guard let s = seg.as(StringSegmentSyntax.self), !s.content.text.contains("\\") else { return nil }
            out += s.content.text
        }
        return out
    }

    /// 寄せ方の属性があるクラスの @Test に付いた宣言は、1台で流す前提と両立しない(クラス側は可)
    static func diagnoseDevicePlacement(placement: ClassPlacementKind?, methods: [ScenarioMethod],
                                        context: some MacroExpansionContext) {
        guard let placement else { return }
        for m in methods {
            guard let node = m.deviceDeclaration.firstNode else { continue }
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: FTDSLDiagnostic(
                    "@\(placement.attributeName) keeps the whole class together (one device or one machine), so a per-test device condition on \(m.name)"
                        + " cannot be honoured separately: move it to the class (@\(node.attributeName.trimmedDescription)"
                        + " on the @TestClass class) or remove @\(placement.attributeName)",
                    id: "device-condition-in-placement-class")))
        }
    }

    /// クラス ∪ テスト。順序・重複は FTCore.DeviceRequirementSet と同じ(クラス → テスト・先勝ち)
    static func mergedDeviceDeclaration(class c: DeviceDeclaration, test t: DeviceDeclaration) -> DeviceDeclaration {
        func dedup(_ xs: [DeviceConditionSpec]) -> [DeviceConditionSpec] {
            var out: [DeviceConditionSpec] = []
            for x in xs where !out.contains(x) { out.append(x) }
            return out
        }
        return DeviceDeclaration(required: dedup(c.required + t.required), excluded: dedup(c.excluded + t.excluded),
                                 firstNode: t.firstNode ?? c.firstNode)
    }

    /// FTCore.DeviceRequirementSet.contradictions の写し(文言も同一)
    static func deviceContradictions(_ d: DeviceDeclaration) -> [String] {
        var out: [String] = []
        if d.required.contains(.physical) && d.required.contains(.virtual) {
            out.append("both physical and virtual are required")
        }
        for c in d.required where d.excluded.contains(c) {
            out.append("\(c.described) is both required and excluded")
        }
        return out
    }

    /// シナリオごとの descriptor の欄(空なら nil = 欄を出さない)。矛盾はここで診断する
    static func deviceRequirementsArg(class c: DeviceDeclaration, method m: ScenarioMethod,
                                      context: some MacroExpansionContext) -> String? {
        let merged = mergedDeviceDeclaration(class: c, test: m.deviceDeclaration)
        guard !merged.isEmpty else { return nil }
        let contradictions = deviceContradictions(merged)
        if !contradictions.isEmpty, let node = merged.firstNode {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: FTDSLDiagnostic(
                    "Device conditions of \(m.name) can never be satisfied: \(contradictions.joined(separator: "; "))",
                    id: "device-condition-contradiction")))
        }
        var parts: [String] = []
        if !merged.required.isEmpty { parts.append("required: [\(merged.required.map(\.emitted).joined(separator: ", "))]") }
        if !merged.excluded.isEmpty { parts.append("excluded: [\(merged.excluded.map(\.emitted).joined(separator: ", "))]") }
        return "\n                deviceRequirements: .init(\(parts.joined(separator: ", "))),"
    }
}

/// マーカーの付け先の検査(クラスは @TestClass 付き・メソッドは @Test 付き)
private func diagnoseDeviceMarkerTarget(_ name: String, node: AttributeSyntax, declaration: some DeclSyntaxProtocol,
                                        context: some MacroExpansionContext) {
    if let cls = declaration.as(ClassDeclSyntax.self) {
        if !TestClassMacro.hasTestClass(cls.attributes) {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: FTDSLDiagnostic("@\(name) requires @TestClass on the same class", id: "device-condition-without-test-class")))
        }
    } else if let fn = declaration.as(FunctionDeclSyntax.self) {
        if TestClassMacro.attribute(named: "Test", in: fn.attributes) == nil {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: FTDSLDiagnostic("@\(name) requires @Test on the same method", id: "device-condition-without-test")))
        }
    } else {
        context.diagnose(Diagnostic(
            node: Syntax(node),
            message: FTDSLDiagnostic("@\(name) can only be attached to a test class or a @Test method", id: "device-condition-target")))
    }
}

public struct RequiresDeviceMacro: PeerMacro {
    public static func expansion(of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol,
                                 in context: some MacroExpansionContext) throws -> [DeclSyntax] {
        diagnoseDeviceMarkerTarget("RequiresDevice", node: node, declaration: declaration, context: context)
        return []
    }
}

public struct ExcludesDeviceMacro: PeerMacro {
    public static func expansion(of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol,
                                 in context: some MacroExpansionContext) throws -> [DeclSyntax] {
        diagnoseDeviceMarkerTarget("ExcludesDevice", node: node, declaration: declaration, context: context)
        return []
    }
}
