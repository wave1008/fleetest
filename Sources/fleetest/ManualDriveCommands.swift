// ManualDriveCommands.swift
// 手動駆動コマンド(install/launch/snapshot/tap/type/swipe/press/screenshot/terminate)

import ArgumentParser
import Foundation
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore
import FTRemote
import FTDSL

// MARK: - 手動駆動コマンド

struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install an app from a package file (iOS: .app bundle / Android: .apk or .apks)")

    @Argument(help: "Path to the package file (iOS: .app bundle / Android: .apk, or .apks via bundletool)")
    var packagePath: String

    @OptionGroup var driverOptions: DriverOptions

    func validate() throws { try driverOptions.rejectDeviceTargetMismatch() }

    func run() async throws {
        guard FileManager.default.fileExists(atPath: packagePath) else {
            throw ValidationError("package file not found: \(packagePath)")
        }
        let note = try await driverOptions.makeDriver().install(packagePath: packagePath)
        if let note { ConsoleOut.err("⚠️ \(note)") }
        ConsoleOut.out("✅ Installed: \(packagePath)")
    }
}

struct Launch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Launch the app under test")

    @Argument(help: "App bundle identifier (e.g. com.example.sampleapp)")
    var bundleID: String

    @OptionGroup var driverOptions: DriverOptions

    func validate() throws { try driverOptions.rejectDeviceTargetMismatch() }

    func run() async throws {
        guard !bundleID.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ValidationError("the app bundle identifier must not be empty")
        }
        // ブリッジ自身は起動しない(撃つとブリッジが自滅する。判定は MCP・DSL・ライブ操作と共有)
        if BridgeSelfApps.isBridgeItself(bundleID) {
            throw ValidationError("\(bundleID) is fleetest's own bridge, not an app under test — launching it would stop"
                + " the bridge itself. Nothing was sent. Pass your app's bundle ID / package.")
        }
        let driver = try await driverOptions.makeDriver()
        try await Self.refuseIfNotInstalled(bundleID: bundleID, driver: driver,
                                            isAndroid: driverOptions.resolvedPlatform == "android")
        try await driver.launch(bundleID: bundleID)
        ConsoleOut.out("✅ Launched: \(bundleID)")
        if bundleID == LiveSessionTarget.springboard {
            ConsoleOut.err("note: this only points the session at SpringBoard (snapshots read its tree); the app in front is not changed")
        }
    }

    /// 撃つ前の門(判定は `InstalledAppCheck.launchGuard` の1箇所。MCP の ft_launch・ライブ操作と共有)。
    /// 未インストールのまま `XCUIApplication.launch()` を撃つと XCUITest ランナーが約60秒ハングして
    /// 自壊する。照会先の udid はブリッジの `/status` から取る —— `/status` が読めない(ブリッジに
    /// 届かない)ときは門を通さず、到達できないことを `launch` 自身に言わせる(落とすランナーが無い)
    static func refuseIfNotInstalled(bundleID: String, driver: AppDriver, isAndroid: Bool) async throws {
        var bridge: String?
        let verdict: InstalledAppCheck.InstallVerdict
        if isAndroid {
            verdict = LaunchInstallVerdict.read(bundleID: bundleID, driver: driver, isAndroid: true, udid: nil)
        } else {
            guard let status = try? await driver.status() else { return }
            bridge = status.bridge
            // 実機の /status は udid を返さない —— ポートの台帳から作った driver の udid で補う
            verdict = LaunchInstallVerdict.read(bundleID: bundleID, driver: driver, isAndroid: false,
                                                udid: status.udid ?? (driver as? BridgeClient)?.physicalUDID)
        }
        switch InstalledAppCheck.launchGuard(
            verdict: verdict, isAndroid: isAndroid, bridge: bridge, bundleID: bundleID) {
        case .allow:
            return
        case .refuse(.notInstalled):
            throw LaunchRefused(message: "\(bundleID) is not installed on this device."
                + " Install it first with `fleetest install <.app or .apk>`, or check the bundle ID"
                + " (Android: the package name)")
        case .refuse(.unknown(let reason)):
            throw LaunchRefused(message: "could not verify whether \(bundleID) is installed (\(reason))."
                + " Launching a missing app can hang the XCUITest bridge and force it to self-terminate"
                + " — retry once the device is less busy, install it first, or double-check the bundle ID")
        }
    }

    struct LaunchRefused: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

struct Snapshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the accessibility tree of the current screen (compressed)")

    @Flag(help: "Print the raw JSON")
    var json = false

    @OptionGroup var driverOptions: DriverOptions

    func validate() throws { try driverOptions.rejectDeviceTargetMismatch() }

    func run() async throws {
        let snapshot = try await driverOptions.makeDriver().snapshot()
        // 利用者が見た木 = 次の `--ref` の古さの照合相手(RefFireGate)
        CLIRefMemo.store(key: driverOptions.refMemoKey, elements: snapshot.elements)
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            ConsoleOut.out(String(data: try encoder.encode(snapshot), encoding: .utf8)!)
        } else {
            // 印の判定は MCP の ft_snapshot と共有(`SnapshotGhostFlags`)。文言は CLI 側で持つ
            let flags = SnapshotGhostFlags.flags(snapshot)
            ConsoleOut.out(SnapshotRenderer.render(snapshot, flagging: flags))
            let values = Set(flags.values)
            if values.contains(SnapshotGhostFlags.offscreenMark) {
                ConsoleOut.out("note: \(SnapshotGhostFlags.offscreenMark) lines are outside the screen (a tap on them lands off-screen)")
            }
            if values.contains(SnapshotGhostFlags.leftoverMark) {
                ConsoleOut.out("note: \(SnapshotGhostFlags.leftoverMark) lines are not drawn where their frames say, so tapping them may hit something else")
            }
        }
    }
}

/// `--ref` の対象を撃つ前に MCP の ft_tap と同じ守り(判定は `FTCore.RefFireCheck` の1箇所)を通す。
/// 撃つ前の木で見る(撃った後だと画面が変わっている)。**キーボードの下・せり上がったバーの覆いは撃たずに非0で断る**
/// (XCUITest は指がキーに落ちて焦点の欄へ文字が入る)。別の物に当たりうる形は撃って ⚠️ を stderr に出す(戻り値)。
/// 木を読めない・ref が無いときは守りなし(撃って答えをそのまま見せる)。**ref を撃つ CLI の手は全部これを通す**
enum RefFireGate {
    /// `memoKey`: 呼び出しをまたぐ ref の控え(`CLIRefMemo`)の鍵。**ここで撮る木が控えと食い違う ref は撃たずに断る**
    /// (撃つ前の守りが木を撮り直すとブリッジの ref の表も今の木になり、ドライバ・ブリッジの照合は素通しになる)
    static func check(driver: AppDriver, ref: Int, isAndroid: Bool, typing: Bool = false,
                      memoKey: String) async throws -> String? {
        guard let snapshot = try? await driver.snapshot() else { return nil }
        let remembered = CLIRefMemo.load(key: memoKey)
        guard let element = snapshot.elements.first(where: { $0.ref == ref }) else { return nil }
        if let detail = RefTableMemo.staleDetail(ref: ref, remembered: remembered, now: element) {
            throw ValidationError("refusing [\(ref)]: \(detail). Nothing was sent. Run `fleetest snapshot` and use the new ref")
        }
        // 断らなかったときだけ控えを今の木へ進める(断った回に進めると、同じ古い ref の撃ち直しが通る)
        CLIRefMemo.store(key: memoKey, elements: snapshot.elements)
        let result = RefFireCheck.evaluate(element, in: snapshot, isAndroid: isAndroid, typing: typing)
        if let refusal = result.refusal { throw ValidationError(refusalMessage(refusal, ref: ref, element: element)) }
        return result.advisory
    }

    static func refusalMessage(_ refusal: RefFireCheck.Refusal, ref: Int, element: ElementInfo) -> String {
        let target = TapTargetGeometry.describe(element)
        switch refusal {
        case .notATextField:
            return "refusing [\(ref)]: \(target) is a \(element.type), not a text field — `type --ref` taps the target first,"
                + " so it would fire (a button, a link). Nothing was sent. Run `fleetest snapshot` and pass the input"
                + " field's ref, or omit --ref to type into the field that has focus"
        case .underKeyboard(let advisory):
            return "refusing [\(ref)]: \(target) — \(advisory). On iOS the finger would press a key and type into the"
                + " focused field. Nothing was sent. Dismiss the keyboard first, then run snapshot again and use the new ref"
        case .keyboardCover(let cover):
            let why: String
            switch cover {
            case .raisedBar(let bar): why = "covered by \(TapTargetGeometry.describe(bar)), which rose above the keyboard"
            case .collapsed: why = "collapsed to a thin band (\(Int(element.frame.width))x\(Int(element.frame.height)))"
            }
            return "refusing [\(ref)]: \(target) is \(why) while the on-screen keyboard is up, so a touch would not land on it."
                + " Nothing was sent. Dismiss the keyboard first, then run snapshot again and use the new ref"
        }
    }
}

/// 操作が届いたか分からない失敗に、撃ち直す前に画面を確かめよと添える(`DriverError.deliveryAdvice`。撃ち直さない)
enum DeliveryAdvice {
    static func relaying(_ fire: () async throws -> Void) async throws {
        do {
            try await fire()
        } catch let error as DriverError {
            if !error.deliveryAdvice.isEmpty { ConsoleOut.err("⚠️ " + error.deliveryAdvice) }
            throw error
        }
    }
}

struct Tap: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Tap an element or a coordinate")

    @Option(help: "Reference number from snapshot")
    var ref: Int?

    @Option(help: "X coordinate — iOS=pt / Android=px (same coordinate system as the snapshot frames)")
    var x: Double?

    @Option(help: "Y coordinate — iOS=pt / Android=px (same coordinate system as the snapshot frames)")
    var y: Double?

    @OptionGroup var driverOptions: DriverOptions

    func validate() throws {
        try driverOptions.rejectDeviceTargetMismatch()
        // 有限でない座標はブリッジへの JSON にできず、Swift の EncodingError がそのまま出ていた(CLI ファズ: --x 1e400)
        for (name, value) in [("--x", x), ("--y", y)] {
            if let value, !value.isFinite { throw ValidationError("\(name) must be a finite number (got \(value))") }
        }
        // ref が勝って座標が黙って捨てられていた(MCP の ft_tap は同じ併用を断る)
        if ref != nil, x != nil || y != nil {
            throw ValidationError("--ref cannot be combined with --x/--y: pass either --ref or --x/--y")
        }
    }

    func run() async throws {
        if let ref {
            let driver = try await driverOptions.makeDriver()
            let note = try await RefFireGate.check(driver: driver, ref: ref, isAndroid: driverOptions.resolvedPlatform == "android",
                                                   memoKey: driverOptions.refMemoKey)
            try await DeliveryAdvice.relaying { try await driver.tap(ref: ref) }
            ConsoleOut.out("✅ tap [\(ref)]")
            if let note { ConsoleOut.err("⚠️ [\(ref)] \(note)") }
        } else if let x, let y {
            let driver = try await driverOptions.makeDriver()
            // 画面の外の座標は撃たずに断る(ライブ操作・MCP と同じ判定 = TapTargetGeometry.isPointOnScreen)。
            // 画面の大きさを読めないときは断らない(撃って、ドライバの答えをそのまま見せる)
            let tree = try? await driver.snapshot()
            if let screen = tree?.screen,
               !TapTargetGeometry.isPointOnScreen(x: x, y: y, screen: screen) {
                throw ValidationError(
                    "(\(FTSeconds.format(x)), \(FTSeconds.format(y))) is outside the screen"
                    + " (\(FTSeconds.format(screen.width))x\(FTSeconds.format(screen.height))) —"
                    + " refusing to send it. Use a point inside the visible screen.")
            }
            // キーボードの中の座標は撃つが言う(キーを押す意図もありうるので断らない。判定は MCP の座標形と共有)
            let keyboardWarning = CoordinateGuards.keyboardFrame(containing: x, y, in: tree) != nil
                ? "(\(FTSeconds.format(x)), \(FTSeconds.format(y))) is inside the soft keyboard — this presses a key, not the app behind it."
                    + " Dismiss the keyboard first unless a key was meant"
                : nil
            try await DeliveryAdvice.relaying { try await driver.tap(x: x, y: y) }
            ConsoleOut.out("✅ tap (\(x), \(y))")
            if let keyboardWarning { ConsoleOut.err("⚠️ \(keyboardWarning)") }
        } else {
            throw ValidationError("specify either --ref or --x/--y")
        }
    }
}

struct TypeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Type text (with --ref, taps the element first)",
        discussion: "Text that starts with '-' (for example -5): put every option first, then `--`, then the text"
            + " — `fleetest type --port 8123 -- -5`.")

    @Option(help: "Reference number of the target field (defaults to the focused element)")
    var ref: Int?

    @Argument(help: "Text to type")
    var text: String

    @OptionGroup var driverOptions: DriverOptions

    func validate() throws { try driverOptions.rejectDeviceTargetMismatch() }

    func run() async throws {
        let driver = try await driverOptions.makeDriver()
        var note: String?
        if let ref {
            note = try await RefFireGate.check(driver: driver, ref: ref, isAndroid: driverOptions.resolvedPlatform == "android",
                                               typing: true, memoKey: driverOptions.refMemoKey)
        }
        try await DeliveryAdvice.relaying { try await driver.type(ref: ref, text: text) }
        ConsoleOut.out("✅ type \"\(text)\"")
        if let ref, let note { ConsoleOut.err("⚠️ [\(ref)] \(note)") }
    }
}

struct Swipe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Swipe")

    @Argument(help: "Direction: up / down / left / right")
    var direction: String

    @OptionGroup var driverOptions: DriverOptions

    func validate() throws { try driverOptions.rejectDeviceTargetMismatch() }

    func run() async throws {
        guard let dir = FTSwipeDirection(rawValue: direction) else {
            throw ValidationError("direction must be one of up / down / left / right")
        }
        let swipeDriver = try await driverOptions.makeDriver()
        try await DeliveryAdvice.relaying { try await swipeDriver.swipe(dir) }
        ConsoleOut.out("✅ swipe \(direction)")
    }
}

struct Press: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Long-press an element")

    @Option(help: "Reference number")
    var ref: Int

    @Option(help: "Press duration in seconds")
    var holdSeconds: Double = 1.0

    @Option(help: "Allow --hold-seconds above the default limit for this press (up to 60)")
    var maxGestureSeconds: Double?

    @OptionGroup var driverOptions: DriverOptions

    func validate() throws {
        try driverOptions.rejectDeviceTargetMismatch()
        // 判定は MCP の ft_long_press と同じ(既定 10 秒・上書きは 60 秒まで = BridgeAPI)。文言は CLI のフラグ名で持つ。0 は撃たない
        if let maxGestureSeconds, BridgeAPI.maxGestureSecondsViolation(maxGestureSeconds) != nil {
            throw ValidationError("--max-gesture-seconds must be greater than 0 and at most"
                + " \(FTSeconds.format(BridgeAPI.gestureSecondsCeiling))s (got \(maxGestureSeconds))")
        }
        let cap = maxGestureSeconds ?? BridgeAPI.defaultMaxGestureSeconds
        guard holdSeconds > 0, BridgeAPI.gestureSecondsViolation(subject: "", seconds: holdSeconds, cap: cap) == nil else {
            let raise = maxGestureSeconds == nil && cap < BridgeAPI.gestureSecondsCeiling
                ? "; pass --max-gesture-seconds (up to \(FTSeconds.format(BridgeAPI.gestureSecondsCeiling))) to allow longer"
                : ""
            throw ValidationError("--hold-seconds must be greater than 0 and at most"
                + " \(FTSeconds.format(cap))s (got \(holdSeconds))" + raise)
        }
    }

    func run() async throws {
        let driver = try await driverOptions.makeDriver()
        let note = try await RefFireGate.check(driver: driver, ref: ref, isAndroid: driverOptions.resolvedPlatform == "android",
                                               memoKey: driverOptions.refMemoKey)
        try await DeliveryAdvice.relaying { try await driver.press(ref: ref, duration: holdSeconds) }
        ConsoleOut.out("✅ press [\(ref)] \(holdSeconds)s")
        if let note { ConsoleOut.err("⚠️ [\(ref)] \(note)") }
    }
}

struct Screenshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Save a screenshot")

    @Option(name: .shortAndLong, help: "Output PNG path")
    var output: String = "screenshot.png"

    @OptionGroup var driverOptions: DriverOptions

    func validate() throws {
        try driverOptions.rejectDeviceTargetMismatch()
        try Self.validateOutputPath(output)
    }

    /// 書き込めない出力先を撮る前に断る(生の Foundation の文言は作業ディレクトリ名や別の名前を指す)
    static func validateOutputPath(_ path: String) throws {
        guard !path.isEmpty else { throw ValidationError("--output must not be empty") }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw ValidationError("--output \(path) is a directory; give a file path such as \(path)/screenshot.png")
        }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var parentIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue else {
            throw ValidationError("--output \(path): the folder \(parent) does not exist")
        }
    }

    func run() async throws {
        let data = try await driverOptions.makeDriver().screenshot()
        try data.write(to: URL(fileURLWithPath: output))
        ConsoleOut.out("✅ Saved: \(output) (\(data.count) bytes)")
    }
}

struct Terminate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Terminate the app under test")

    @OptionGroup var driverOptions: DriverOptions

    func validate() throws { try driverOptions.rejectDeviceTargetMismatch() }

    func run() async throws {
        try await driverOptions.makeDriver().terminate()
        ConsoleOut.out("✅ Terminated")
    }
}
