// BridgeProvisionerTypes.swift
// BridgeProvisioner(BridgeProvisioner.swift)の結果とエラーの型

import Foundation
import FTCore

public struct ProvisionedIOSDevice: Sendable {
    /// 実行プロファイル上のデバイス名(例: simulator1)
    public let name: String
    public let udid: String
    public let simulatorName: String
    /// 主ブリッジのポート。inapp-boost モードでは in-app ブリッジのポート
    public let port: UInt16
    /// モード(`IOSMode`)。DriverConnection 経由でサブプロセスへ伝える
    public let mode: String
    /// inapp-boost モードで撃てない操作を回す XCUITest ブリッジのポート(xcuitest モードは nil)
    public let xcuiPort: UInt16?
    /// 実機か(kind=physical)。simctl 依存の経路を止める分岐に使う
    public let physical: Bool
    /// ブリッジへの到達先ホスト。シミュレータは 127.0.0.1、実機は LAN IP か iproxy のループバック
    public let host: String
    /// 実行プロファイルが頼んだモード(mode と違えば縮退した = 結果の記録 `workerModes` へ残す)
    public let requestedMode: String
    /// 縮退したときだけ、その理由(InAppCodeSign.inspect の一次情報)
    public let modeFallbackReason: String?

    /// requestedMode / modeFallbackReason は**既定値を置かない**(渡し忘れで縮退の記録が黙って欠ける)
    public init(name: String, udid: String, simulatorName: String, port: UInt16,
                mode: String, xcuiPort: UInt16? = nil,
                physical: Bool = false, host: String = BridgeEndpoint.loopbackHost,
                requestedMode: String, modeFallbackReason: String?) {
        self.requestedMode = requestedMode
        self.modeFallbackReason = modeFallbackReason
        self.name = name
        self.udid = udid
        self.simulatorName = simulatorName
        self.port = port
        self.mode = mode
        self.xcuiPort = xcuiPort
        self.physical = physical
        self.host = host
    }
}

public enum BridgeProvisionerError: Error, LocalizedError {
    case noFreePort(scanned: ClosedRange<UInt16>)
    /// waitUntilReady() が失敗した場合(後始末として起動済みプロセス/pidファイルは停止済み)
    case notReady(port: UInt16, underlying: Error)
    /// bridge="inapp" のブリッジを新規起動するのに bundleID が無い(フォールバックしない=単一実装)
    case inAppNeedsBundleID(name: String)
    /// bridge=inapp でアプリ未インストール・preinstallAppPath も無い(provision() が該当デバイスのみ離脱)
    case appNotInstalled(device: String, bundleID: String, udid: String)
    /// preinstallAppPath 指定時の simctl install 自体が失敗した
    case preinstallFailed(device: String, detail: String)
    /// 実機がロックされたまま解除を待ち切った(起動しても SpringBoard に拒否されるので撃たない)
    case deviceLocked(name: String, waited: TimeInterval)
    /// 印(RunnerSlowness.runnerRestartDidNotHelp)があるデバイスのシミュレータ再起動(shutdown/boot)が失敗した
    case simulatorRebootFailed(name: String, detail: String)
    /// 回復の最後の手としてのシミュレータの初期化(SimulatorEraseForRecovery)が失敗した
    case simulatorEraseFailed(name: String, detail: String)
    /// 起動し直した直後のランナーが 1 問にも答えなかった(測った事実)。このデバイスは今回の run では使えない
    case runnerNotAnswering(name: String, port: UInt16, waited: TimeInterval)
    /// 別の実在するワークスペースの、再利用できないブリッジがこのデバイスに居る(BridgePlan.blockedByForeign)。
    /// 止めると相手の run を壊すので止めない
    case foreignBridgeInTheWay(name: String, port: UInt16, owner: String, reason: String)
    /// 引き取ろうとしたランナーが答えないが、そのデバイスを他のセッション(run・MCP・ライブ操作)が使っている。
    /// 操作の処理中で /status に答えないだけのことがあり、止めるとそのセッションの操作ごと落ちる(B5)
    case unresponsiveBridgeHeldByAnotherSession(name: String, port: UInt16)

    public var errorDescription: String? {
        switch self {
        case .noFreePort(let scanned):
            // **次の一手を添える** —— この失敗は run ごと落とすのに、「何が塞いでいるか」も
            // 「どう空けるか」も言っていなかった(実地の負荷テスト: フル編成 +
            // MCP のセッション + 実機のトンネルで 32 ポートが埋まり、`--broadcast` が全滅した)。
            // 窓は1台あたり最大2本(in-app + xcuitest)なので、台数が増えると普通に届く
            return "no free port (scanned \(scanned.lowerBound)-\(scanned.upperBound));"
                + " every port in the bridge window is taken (a device can hold two: in-app and"
                + " xcuitest). `fleetest bridge status` lists them, `fleetest doctor` names"
                + " leftovers whose bridge is gone, and `fleetest bridge down --port <n>` frees one"
        case .notReady(let port, let underlying):
            // **取り消しは「時間内に準備ができなかった」と言わない**: 待ちを切ったのは呼び手(蘇生の枠・run の中断)で、
            // ブリッジ自身の起動の期限ではない(蘇生の枠が SpringBoard の起こし直しの途中で尽きた回に
            // 「did not become ready in time … CancellationError」と出ていた)
            if underlying is CancellationError {
                return "starting the bridge was cancelled before it became ready (port \(port)):"
                    + " the caller stopped waiting for it"
            }
            // localizedDescription を使う。素の enum を補間すると
            // addressNotAnnounced(port: 8133, logPath: "...", blocker: Optional("..."))
            // のような内部表現がそのままユーザーに出る(実害)
            return "the bridge did not become ready in time (port \(port)): "
                + underlying.localizedDescription
        case .inAppNeedsBundleID(let name):
            return "\(name): starting the in-app bridge requires the app bundleID. "
                + "Set ios.app in the apps profile"
                + " (paths that do not pass a bundleID, such as device/live, do not support inapp-boost mode)"
        case .appNotInstalled(_, let bundleID, let udid):
            // device 名は provision() の離脱ログが行頭に付けるためここには含めない
            return "\(bundleID) is not installed, so this device drops out (the in-app bridge requires it up front). "
                + "Install it with `xcrun simctl install \(udid) <app>`, "
                + "or set appPath + autoInstall in the apps profile"
        case .deviceLocked(let name, let waited):
            return "\(name) stayed locked for \(Int(waited))s. Unlock the device and run again "
                + "(the runner cannot be launched on a locked device; once it is up it keeps the "
                + "device awake, so this is only needed when the bridge is (re)built)"
        case .preinstallFailed(let device, let detail):
            return "\(device): automatic app install failed:\n\(detail)"
        case .simulatorRebootFailed(let name, let detail):
            return "\(name): rebooting the simulator failed: \(detail)"
        case .simulatorEraseFailed(let name, let detail):
            return "\(name): erasing the simulator failed: \(detail)"
        case .runnerNotAnswering(let name, let port, let waited):
            return "\(name): the xcuitest bridge on port \(port) did not answer a one-element accessibility"
                + " query within \(Int(waited.rounded()))s even after it was restarted, so this device is"
                + " not used in this run"
        case .foreignBridgeInTheWay(let name, let port, let owner, let reason):
            return "\(name): the \(reason) on port \(port) belongs to another workspace (\(owner))"
                + " — not stopping it, because that would break the other workspace's runs."
                + " Stop it from there (`fleetest bridge down --port \(port)` in that workspace) and run again"
        case .unresponsiveBridgeHeldByAnotherSession(let name, let port):
            // 「別のセッション」は印(lease)を持つ誰か —— 自分の MCP も含む。固まったトンネルも無応答で同じに見えるので出口を添える
            return RunnerAccessibilityHealth.deviceHeldByAnotherSessionMessage(
                device: name, what: "restarting the bridge on port \(port), which is not answering right now")
                + ". If no other session is actually driving it (a stuck bridge or USB tunnel looks the same),"
                + " `fleetest bridge down --port \(port) --force` stops it and the next `bridge up` starts a fresh one"
        }
    }
}
