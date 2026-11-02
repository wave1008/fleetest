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
        // ブリッジ自身は起動しない(撃つとブリッジが自滅する。判定は MCP・DSL と共有)
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

    /// 撃つ前の門(判定は `InstalledAppCheck.launchGuard` の1箇所。MCP の ft_launch と共有)。
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

/// 座標で撃つ手(tap / press)が撃つ前に通す守り(画面の外 = ライブ操作・MCP と共有の `TapTargetGeometry.isPointOnScreen` /
/// キーボードの中 = MCP と共有の `CoordinateGuards.keyboardFrame`)。画面の外は撃たずに断る。キーボードの中は撃つ(キーを押す意図もありうる)が ⚠️ を返す。
/// 画面の大きさを読めないときは断らない(撃って、ドライバの答えをそのまま見せる)。**座標で撃つ CLI の手は全部これを通す**
enum CoordinateFireGate {
    static func check(driver: AppDriver, x: Double, y: Double) async throws -> String? {
        let tree = try? await driver.snapshot()
        if let screen = tree?.screen,
           !TapTargetGeometry.isPointOnScreen(x: x, y: y, screen: screen) {
            throw ValidationError(
                "(\(FTSeconds.format(x)), \(FTSeconds.format(y))) is outside the screen"
                + " (\(FTSeconds.format(screen.width))x\(FTSeconds.format(screen.height))) —"
                + " refusing to send it. Use a point inside the visible screen.")
        }
        guard CoordinateGuards.keyboardFrame(containing: x, y, in: tree) != nil else { return nil }
        return "(\(FTSeconds.format(x)), \(FTSeconds.format(y))) is inside the soft keyboard — this presses a key, not the app behind it."
            + " Dismiss the keyboard first unless a key was meant"
    }

    /// 有限でない座標はブリッジへの JSON にできず、Swift の EncodingError がそのまま出ていた(CLI ファズ: --x 1e400)
    static func validateFinite(x: Double, y: Double) throws {
        for (name, value) in [("--x", x), ("--y", y)] where !value.isFinite {
            throw ValidationError("\(name) must be a finite number (got \(value))")
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
    static let configuration = CommandConfiguration(abstract: "Tap a coordinate")

    @Option(help: "X coordinate — iOS=pt / Android=px (same coordinate system as the snapshot frames)")
    var x: Double

    @Option(help: "Y coordinate — iOS=pt / Android=px (same coordinate system as the snapshot frames)")
    var y: Double

    @OptionGroup var driverOptions: DriverOptions

    func validate() throws {
        try driverOptions.rejectDeviceTargetMismatch()
        try CoordinateFireGate.validateFinite(x: x, y: y)
    }

    func run() async throws {
        let driver = try await driverOptions.makeDriver()
        let keyboardWarning = try await CoordinateFireGate.check(driver: driver, x: x, y: y)
        try await DeliveryAdvice.relaying { try await driver.tap(x: x, y: y) }
        ConsoleOut.out("✅ tap (\(x), \(y))")
        if let keyboardWarning { ConsoleOut.err("⚠️ \(keyboardWarning)") }
    }
}

struct TypeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Type text into the focused element",
        discussion: "Text that starts with '-' (for example -5): put every option first, then `--`, then the text"
            + " — `fleetest type --port 8123 -- -5`.")

    @Argument(help: "Text to type")
    var text: String

    @OptionGroup var driverOptions: DriverOptions

    func validate() throws { try driverOptions.rejectDeviceTargetMismatch() }

    /// 文中の改行の後ろに文字がある入力への注記(無ければ nil)。1行の欄は改行で入力が確定/打ち切られ、後ろが入らないことがあるが、
    /// `type` は読み返さないので成功と区別できない。欄の種類を知らないので「入らないことがある」と言う
    static func lineBreakNote(_ text: String) -> String? {
        let parts = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard parts.count > 1, parts.dropFirst().contains(where: { !$0.isEmpty }) else { return nil }
        return "the text contains a line break followed by more text; a single-line field may not take the part after it"
            + " — type does not read the field back, so check it (snapshot) before relying on it"
    }

    func run() async throws {
        let driver = try await driverOptions.makeDriver()
        try await DeliveryAdvice.relaying { try await driver.type(ref: nil, text: text) }
        ConsoleOut.out("✅ type \"\(text)\"")
        if let lineBreak = Self.lineBreakNote(text) { ConsoleOut.err("⚠️ \(lineBreak)") }
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
    static let configuration = CommandConfiguration(abstract: "Long-press a coordinate")

    @Option(help: "X coordinate — iOS=pt / Android=px (same coordinate system as the snapshot frames)")
    var x: Double

    @Option(help: "Y coordinate — iOS=pt / Android=px (same coordinate system as the snapshot frames)")
    var y: Double

    @Option(help: "Press duration in seconds")
    var holdSeconds: Double = 1.0

    @Option(help: "Allow --hold-seconds above the default limit for this press (up to 60)")
    var maxGestureSeconds: Double?

    @OptionGroup var driverOptions: DriverOptions

    func validate() throws {
        try driverOptions.rejectDeviceTargetMismatch()
        try CoordinateFireGate.validateFinite(x: x, y: y)
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
        let keyboardWarning = try await CoordinateFireGate.check(driver: driver, x: x, y: y)
        try await DeliveryAdvice.relaying { try await driver.press(x: x, y: y, duration: holdSeconds) }
        ConsoleOut.out("✅ press (\(x), \(y)) \(holdSeconds)s")
        if let keyboardWarning { ConsoleOut.err("⚠️ \(keyboardWarning)") }
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
