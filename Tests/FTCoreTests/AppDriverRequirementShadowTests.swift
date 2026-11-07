import XCTest

/// **既定引数付きの別のシグネチャは AppDriver の要件の実装にならない**。`func home(bundleID: String? = nil)` だけを持つ型は
/// `home()` を実装したつもりで、存在型越しの `base.home()` が AppDriver の既定実装(501)に落ちる(ビルドもテストも通る。
/// xcuitest モードの `home()` と MCP の `ft_navigate home` が常に赤 = 35周目 phys F1)。
/// 走査: 要件と同じ名前で、既定引数を除いたラベルの並びが要件と一致する宣言があれば、同じファイルに要件どおりの宣言も要る
final class AppDriverRequirementShadowTests: XCTestCase {
    private struct Decl: Hashable { let name: String; let labels: [String]; let requiredLabels: [String] }

    private func flatten(_ source: String) -> String {
        source.split(whereSeparator: { $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .joined(separator: " ")
    }

    private func decls(in text: String) -> [Decl] {
        let regex = try! NSRegularExpression(pattern: #"\bfunc (\w+)\(([^()]*)\)"#)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            let name = ns.substring(with: match.range(at: 1))
            let params = ns.substring(with: match.range(at: 2)).split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            var labels: [String] = [], required: [String] = []
            for param in params {
                let label = String(param.split(separator: ":").first ?? "")
                    .split(separator: " ").first.map(String.init) ?? ""
                labels.append(label)
                if !param.contains("=") { required.append(label) }
            }
            return Decl(name: name, labels: labels, requiredLabels: required)
        }
    }

    func testNoDefaultedVariantStandsInForARequirement() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let protocolSource = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/AppDriver.swift"), encoding: .utf8)
        guard let start = protocolSource.range(of: "public protocol AppDriver {"),
              let end = protocolSource.range(of: "\n}", range: start.upperBound..<protocolSource.endIndex) else {
            return XCTFail("AppDriver のプロトコル本体が見つからない")
        }
        let requirements = decls(in: flatten(String(protocolSource[start.upperBound..<end.lowerBound])))
        XCTAssertTrue(requirements.contains { $0.name == "home" && $0.labels.isEmpty }, "要件の走査が壊れている")
        let requirementKeys = Set(requirements.map { "\($0.name)(\($0.labels.joined(separator: ",")))" })

        var scanned = 0
        var shadows: [String] = []
        let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            // FTDSL は DSL の公開関数(`home(file:line:)` 等 = 既定引数付きでドライバではない)なので外す
            guard url.pathExtension == "swift", url.lastPathComponent != "AppDriver.swift", !url.path.contains("/Sources/FTDSL/"),
                  let source = try? String(contentsOf: url, encoding: .utf8), source.contains("AppDriver") else { continue }
            scanned += 1
            let found = decls(in: flatten(source))
            let exact = Set(found.map { "\($0.name)(\($0.labels.joined(separator: ",")))" })
            for decl in found where decl.labels != decl.requiredLabels {
                let shadowed = "\(decl.name)(\(decl.requiredLabels.joined(separator: ",")))"
                if requirementKeys.contains(shadowed), !exact.contains(shadowed) {
                    shadows.append("\(url.lastPathComponent): func \(decl.name)(\(decl.labels.joined(separator: ", "))) stands in for \(shadowed)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 10, "走査が Sources に届いていない")
        XCTAssertEqual(shadows, [], "既定引数付きの宣言だけで要件を満たしたつもりの型がある(要件どおりの宣言を足すこと)")
    }
}
