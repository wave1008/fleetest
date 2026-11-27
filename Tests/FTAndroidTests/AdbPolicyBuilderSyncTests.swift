// サンドボックスの中の adb は親が `AdbPolicy`(FTCore)の許す形だけ代行する。FTAndroid が組み立てる引数が
// 表から外れると、サンドボックスの中でだけその操作が断られる(枠の外の単体テストは緑のまま)。
// ここで組み立て側の出力を表に当てて、片方だけの変更を落とす。

import Foundation
import XCTest
@testable import FTAndroid
import FTCore

private extension SimctlPolicy.Context {
    var withBundletool: SimctlPolicy.Context {
        var copy = self
        copy.bundletool = ["/parent/bundletool"]
        return copy
    }
}

final class AdbPolicyBuilderSyncTests: XCTestCase {

    private let context = SimctlPolicy.Context(udid: nil, deviceName: nil, toolRoots: [], childWritableRoots: [],
                                               serial: "emulator-5554", adbPath: "/parent/adb")

    private func assertAllowed(_ args: [String], file: StaticString = #filePath, line: UInt = #line) {
        let refusal = AdbPolicy.check(["-s", "emulator-5554"] + args, context: context)
        XCTAssertNil(refusal, "\(args) — \(refusal?.reason ?? "")", file: file, line: line)
    }

    func testBuildersProduceShapesThePolicyAllows() throws {
        assertAllowed(try AndroidDriver.amStartArgs(url: "fte2e://screen/detail?x=1&y=2", package: nil))
        assertAllowed(try AndroidDriver.amStartArgs(url: "https://example.com/a b", package: "com.ftester.e2e"))
        assertAllowed(try XCTUnwrap(AndroidWebViewDOM.probeCommand(packageID: "com.ftester.e2e")))
        assertAllowed(try XCTUnwrap(WebViewDOMFallback.probeCommand(packageID: "com.ftester.e2e")))
        assertAllowed(["shell", AndroidPhysicalDevice.screenCheckCommand])
        assertAllowed(["shell", AdbPolicy.foldStateCommand])
        for degrees in [0, 130, 180, 12.5] { assertAllowed(AndroidDriver.hingeArguments(degrees: degrees)) }
        assertAllowed(["shell", "pm path \(AndroidDriver.bridgePackage) 2>/dev/null; echo \(AndroidDriver.pmPathMarker)"])
        for ttl in [60, 3600] {
            for owner in [nil, "/Users/me/my repo"] as [String?] {
                for timing in [false, true] {
                    assertAllowed(["shell", AndroidDriver.instrumentCommand(ttl: ttl, ownerPath: owner, timing: timing)])
                }
            }
        }
        for key in AnimationPolicy.androidScaleKeys {
            assertAllowed(["shell"] + AndroidAnimationSettings.getArguments(key: key))
            for enabled in [false, true] {
                assertAllowed(["shell"] + AndroidAnimationSettings.putArguments(key: key, animationsEnabled: enabled))
            }
        }
        assertAllowed(AdbInstallVerifier.readArguments)
        assertAllowed(AdbInstallVerifier.disableArguments)
        assertAllowed(AdbInstallVerifier.restoreArguments(original: "1"))
        assertAllowed(AdbInstallVerifier.restoreArguments(original: "null"))
    }

    /// `.apks` のインストール(bundletool)の組み立ても親の表に通ること
    func testSplitBundleInstallArgumentsArePassedByTheBroker() {
        let argv = ApksBundle.installArgs(bundletool: ["/opt/homebrew/bin/bundletool"], apksPath: "/apps/App.apks",
                                          serial: "emulator-5554", adb: "/sdk/platform-tools/adb")
        XCTAssertNil(BrokerPolicy.check(argv, context: context.withBundletool))
        let jarArgv = ApksBundle.installArgs(bundletool: ["java", "-jar", "/tools/bundletool.jar"],
                                             apksPath: "/apps/App.apks", serial: "emulator-5554", adb: "/sdk/adb")
        XCTAssertNil(BrokerPolicy.check(jarArgv, context: context.withBundletool))
    }

    /// owner のパスに `'` があると端末の sh のクォートが壊れる(表にも断られる)ので付けない
    func testInstrumentCommandDropsAnOwnerPathItCannotQuote() {
        let command = AndroidDriver.instrumentCommand(ttl: 60, ownerPath: "/Users/o'neil/repo", timing: false)
        XCTAssertFalse(command.contains("-e owner"), command)
        assertAllowed(["shell", command])
    }

    /// 定数だけで書いた adb の呼び出し(`adb([...])` 等。`["shell"] + x` のように続くものは除く)を走査し、表に通ることを見る。
    /// 新しい呼び出しを足して表に足し忘れると落ちる(値が入る呼び出しは上の組み立ての検査で見る)
    func testLiteralAdbCallsInTheDriverAreAllowed() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTAndroid")
        let call = try NSRegularExpression(pattern: #"\b(?:adb|adbAnswering|adbProbe|rawAdb)\(\[((?:"[^"\\]*"(?:,\s*)?)+)\]\s*[,)]"#)
        let literal = try NSRegularExpression(pattern: #""([^"\\]*)""#)
        var checked = 0
        // AndroidDriver は extension のファイル(AndroidDriver+*.swift)に分かれている = 全部読む(本体だけだと移した呼び出しが黙って外れる)
        let driverFiles = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("AndroidDriver") && $0.hasSuffix(".swift") }.sorted()
        XCTAssertTrue(driverFiles.contains("AndroidDriver+InstalledPackages.swift"), "走査が extension のファイルに届いていない")
        for name in driverFiles + ["AndroidBridge.swift"] {
            let source = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            for match in call.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let list = String(source[Range(match.range(at: 1), in: source)!])
                let args = literal.matches(in: list, range: NSRange(list.startIndex..., in: list)).map {
                    String(list[Range($0.range(at: 1), in: list)!])
                }
                checked += 1
                assertAllowed(args)
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 20, "走査が呼び出しに届いていない")
    }
}

/// simctl / devicectl も adb と同じ規律: 子(サンドボックスの中)から呼ぶ形は `SimctlPolicy` / `DevicectlPolicy`(SandboxBroker.swift)に載せる。
/// Sources の呼び出しを走査し、方針と表を **両方向** で突き合わせる(足し忘れも、呼び手が消えた方針の残りも落とす)。
/// 親だけが呼ぶ形は下の表に載せる(シナリオ実行バイナリの経路 = FTScenarioRunner・FTDSL・StepExecutor から呼ばれない)
final class SimctlDevicectlPolicySourceSyncTests: XCTestCase {

    private let context = SimctlPolicy.Context(udid: "UDID-1", deviceName: nil, toolRoots: [], childWritableRoots: [])

    private static let sourcesRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    /// 親(供給・回復・モニター・録画・devices)だけが呼ぶので方針に載せない simctl の動詞(動詞 → 呼ぶファイル)
    private let parentOnlyVerbs: [String: Set<String>] = [
        "create": ["VirtualDeviceFactory.swift"],
        "delete": ["DeviceDeletion.swift"],
        "erase": ["DeviceWiper.swift", "SimulatorEraseForRecovery.swift"],
        "io": ["HostRecordingProbe.swift", "IOSSimulatorVideoRecorder.swift", "SimulatorActiveDisplay.swift"],
        "shutdown": ["DevicesCommand.swift", "DisplayFreezeWatch.swift", "ProfileWorkerFactory.swift",
                     "SimulatorBoot.swift", "SimulatorShutdownRetry.swift"],
        "ui": ["SimulatorAppearanceArbiter.swift"],
    ]

    /// 動詞は方針にあるが、親だけが呼ぶので方針が断ってよい定数の形(形 → 呼ぶファイル)
    private let parentOnlyCalls: [String: Set<String>] = [
        "list -j devices": ["SimulatorCatalog.swift"],
        "list -j devicetypes devices": ["IOSDeviceKindResolver.swift"],
        "list -j devicetypes": ["ApiDeviceCatalogCommand.swift", "IOSRuntimeInstaller.swift", "VirtualDeviceFactory.swift"],
        "list -j runtimes": ["ApiDeviceCatalogCommand.swift", "IOSRuntimeInstaller.swift", "VirtualDeviceFactory.swift"],
        "list devices": ["ScreenRenderingRecoverer.swift"],
        "list devices booted": ["DoctorCommand.swift"],
        "spawn launchctl kickstart -k system/com.apple.SpringBoard": ["SimulatorSpringBoard.swift"],
        "spawn launchctl kickstart -k system/com.apple.backboardd": ["SimulatorDisplayServer.swift"],
        "spawn defaults read -g AppleLanguages": ["SimulatorEraseForRecovery.swift"],
        "spawn defaults read -g AppleLocale": ["SimulatorEraseForRecovery.swift"],
        "spawn defaults read com.apple.Accessibility ReduceMotionEnabled": ["DoctorCommand.swift"],
        "spawn defaults write -g AppleLanguages -array": ["SimulatorEraseForRecovery.swift"],
        "spawn defaults write com.apple.keyboard.preferences AutomaticMinimizationEnabled -bool false":
            ["IOSSoftwareKeyboard.swift"],
    ]

    private func sources() throws -> [(name: String, text: String)] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: Self.sourcesRoot, includingPropertiesForKeys: nil))
        var files: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" && url.lastPathComponent != "SandboxBroker.swift" {
            files.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return files
    }

    private func groups(_ pattern: String, in text: String) throws -> [[String]] {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
        }
    }

    private func literals(_ list: String) throws -> [String] {
        try groups(#""([^"\\]*)""#, in: list).map { $0[0] }
    }

    private func policySource(from start: String, to end: String) throws -> String {
        let url = Self.sourcesRoot.appendingPathComponent("FTCore/SandboxBroker.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let from = try XCTUnwrap(text.range(of: start), "\(start) が SandboxBroker.swift に無い")
        let to = try XCTUnwrap(text.range(of: end), "\(end) が SandboxBroker.swift に無い")
        return String(text[from.lowerBound..<to.lowerBound])
    }

    func testEverySimctlCallInTheSourcesIsInThePolicyOrListedAsParentOnly() throws {
        let region = try policySource(from: "public enum SimctlPolicy", to: "public enum DevicectlPolicy")
        let policyVerbs = Set(try groups(#"(?m)^\s*case ((?:"[a-z_]+"(?:,\s*)?)+):"#, in: region)
            .flatMap { try literals($0[0]) })
        XCTAssertGreaterThanOrEqual(policyVerbs.count, 10, "SimctlPolicy の動詞を読めていない(定義の形が変わった)")

        var verbSites = Set<String>()
        var callSites = Set<String>()
        var problems: [String] = []
        for (name, text) in try sources() {
            for g in try groups(#"(?:"xcrun",\s*|arguments = \[)"simctl",\s*"([a-z_]+)""#, in: text) {
                verbSites.insert("\(g[0])|\(name)")
                if !policyVerbs.contains(g[0]), !(parentOnlyVerbs[g[0]]?.contains(name) ?? false) {
                    problems.append("\(name): simctl \(g[0]) が SimctlPolicy にも parentOnlyVerbs にも無い")
                }
            }
            // 定数だけの呼び出しと、`simctl spawn <udid>` の後ろが定数の呼び出し(udid は方針の通る値に置き換える)
            var calls: [(key: String, argv: [String])] = []
            for g in try groups(#"\["xcrun",\s*"simctl",\s*((?:"[^"\\]*"(?:,\s*)?)+)\]"#, in: text) {
                let tail = try literals(g[0])
                calls.append((tail.joined(separator: " "), ["xcrun", "simctl"] + tail))
            }
            for g in try groups(#""simctl",\s*"spawn",\s*[\w.]+,\s*((?:"[^"\\]*"(?:,\s*)?)+)\]"#, in: text) {
                let tail = try literals(g[0])
                calls.append((("spawn " + tail.joined(separator: " ")), ["xcrun", "simctl", "spawn", "UDID-1"] + tail))
            }
            for call in calls where policyVerbs.contains(call.argv[2]) {
                callSites.insert("\(call.key)|\(name)")
                guard BrokerPolicy.check(call.argv, context: context) != nil else { continue }
                if !(parentOnlyCalls[call.key]?.contains(name) ?? false) {
                    problems.append("\(name): `\(call.key)` を SimctlPolicy が断る。子から呼ぶなら SimctlPolicy に形を足し、親だけなら parentOnlyCalls に足す")
                }
            }
        }
        XCTAssertGreaterThanOrEqual(verbSites.count, 30, "走査が simctl の呼び出しに届いていない")
        XCTAssertEqual(problems.sorted(), [])

        let staleVerbs = policyVerbs.filter { verb in !verbSites.contains { $0.hasPrefix("\(verb)|") } }
        XCTAssertEqual(staleVerbs.sorted(), [], "SimctlPolicy に動詞があるが Sources に呼び手が無い(方針の残りを消す)")
        let staleVerbRows = parentOnlyVerbs.flatMap { verb, files in files.map { "\(verb)|\($0)" } }
            .filter { !verbSites.contains($0) }
        XCTAssertEqual(staleVerbRows.sorted(), [], "parentOnlyVerbs に載っているが呼び手が無い行(表から消す)")
        let staleCallRows = parentOnlyCalls.flatMap { key, files in files.map { "\(key)|\($0)" } }
            .filter { !callSites.contains($0) }
        XCTAssertEqual(staleCallRows.sorted(), [], "parentOnlyCalls に載っているが呼び手が無い行(表から消す)")
    }

    func testDevicectlCallsInTheSourcesMatchThePolicyBothWays() throws {
        let region = try policySource(from: "public enum DevicectlPolicy", to: "public enum BrokerPolicy")
        var policyHeads = Set<String>()
        for pattern in [#"Array\(a\[0\.\.<4\]\) == \[((?:"[^"]+"(?:,\s*)?)+)\]"#, #"case \[((?:"[^"]+"(?:,\s*)?)+)\]:"#] {
            for g in try groups(pattern, in: region) {
                policyHeads.insert(try literals(g[0]).prefix(3).joined(separator: " "))
            }
        }
        var calledHeads = Set<String>()
        for (_, text) in try sources() {
            for g in try groups(#""xcrun",\s*"devicectl",\s*"([^"]+)",\s*"([^"]+)",\s*"([^"]+)""#, in: text) {
                calledHeads.insert(g.joined(separator: " "))
            }
        }
        XCTAssertGreaterThanOrEqual(policyHeads.count, 10, "DevicectlPolicy の形を読めていない(定義の形が変わった)")
        XCTAssertGreaterThanOrEqual(calledHeads.count, 10, "走査が devicectl の呼び出しに届いていない")
        XCTAssertEqual(calledHeads.subtracting(policyHeads).sorted(), [],
                       "呼び出しがあるが DevicectlPolicy に形が無い(子から呼ぶなら SandboxBroker.swift に足す)")
        XCTAssertEqual(policyHeads.subtracting(calledHeads).sorted(), [],
                       "DevicectlPolicy に形があるが Sources に呼び手が無い(方針の残りを消す)")
    }
}
