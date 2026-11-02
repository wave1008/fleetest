// `DriverAnswers`(構成ごとに答えられる観測の表)と本物のドライバの実装を突き合わせる(ソース走査)。
// 観測の既定は `.notAnswerable` を返すので、実装の書き忘れも素通しの書き忘れもコンパイルが通り、判定が黙って届かなくなる
// (既存の DefaultImplementationForwardingTests は「501 を投げる既定」だけを見ており、観測は対象外)。

import XCTest
import FTCore

final class DriverAnswersConformanceTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTBridgeClientTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
    }

    /// 表の各観測と AppDriver の要件の名前
    private static let observations: [(DriverAnswers, String)] = [
        (.foregroundAppID, "foregroundAppID"),
        (.keyguardShowing, "keyguardShowing"),
        (.systemAlert, "systemAlert"),
        (.systemUICovering, "systemUICovering"),
    ]

    private func source(_ path: String) throws -> String {
        let text = try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// 要件の4つが全部 `Probe` を返す形で走査の対象になっていること(名前の取り違えで走査が空振りしない)
    func testObservationNamesAreTheProtocolRequirements() throws {
        let protocolSource = try source("Sources/FTCore/AppDriver.swift")
        for (_, name) in Self.observations {
            XCTAssertTrue(protocolSource.contains("func \(name)() async -> Probe<"), name)
        }
        XCTAssertEqual(Self.observations.reduce(DriverAnswers()) { $0.union($1.0) },
                       [.foregroundAppID, .keyguardShowing, .systemAlert, .systemUICovering])
    }

    /// 葉のドライバは表で「答える」観測だけを実装し、「答えない」観測は既定(`.notAnswerable`)に任せる
    func testLeafDriversImplementExactlyTheObservationsTheirTableRowAnswers() throws {
        let leaves: [(String, DriverAnswers)] = [
            ("Sources/FTBridgeClient/BridgeClient.swift", .iosXCUITest),
            ("Sources/FTBridgeClient/InAppDriver.swift", .iosInApp),
            ("Sources/FTAndroid/AndroidDriver.swift", .android),
        ]
        var mismatches: [String] = []
        for (path, answers) in leaves {
            let text = try source(path)
            for (observation, name) in Self.observations {
                let implements = text.contains("func \(name)() async -> Probe<")
                if implements != answers.contains(observation) {
                    mismatches.append("\(path): \(name) は表では\(answers.contains(observation) ? "答える" : "答えない")のに"
                        + "\(implements ? "実装している" : "実装していない")")
                }
            }
        }
        XCTAssertTrue(mismatches.isEmpty, mismatches.joined(separator: "\n"))
    }

    /// 包むドライバは、包む相手が答えうる観測を素通しする(書き忘れると既定の `.notAnswerable` に落ちて黙る)。
    /// iOS の包むドライバは iOS の構成が答える観測、ActionCountingDriver は OS を問わず包むので4つ全部
    func testWrappersForwardTheObservationsTheirBaseCanAnswer() throws {
        let iosAnswers = DriverAnswers.iosXCUITest.union(.iosInAppBoost).union(.iosInApp)
        let dir = Self.repoRoot.appendingPathComponent("Sources/FTBridgeClient")
        let wrappers = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
            .filter { $0.hasSuffix("Driver.swift") && $0 != "InAppDriver.swift" }   // InAppDriver は葉
            .sorted()
        XCTAssertGreaterThanOrEqual(wrappers.count, 7, "走査対象の包むドライバが見つからない: \(wrappers)")
        var targets = wrappers.map { ("Sources/FTBridgeClient/\($0)", iosAnswers) }
        targets.append(("Sources/FTCore/ActionCountingDriver.swift",
                        [.foregroundAppID, .keyguardShowing, .systemAlert, .systemUICovering]))
        var missing: [String] = []
        for (path, required) in targets {
            let text = try source(path)
            for (observation, name) in Self.observations where required.contains(observation) {
                if !text.contains("func \(name)() async -> Probe<") { missing.append("\(path): \(name)") }
            }
        }
        XCTAssertTrue(missing.isEmpty, "観測の素通しが無い(既定の .notAnswerable に落ちる): \(missing)")
    }
}
