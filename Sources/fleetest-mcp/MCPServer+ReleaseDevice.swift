// MCPServer+ReleaseDevice.swift
// ft_release_device: このセッションのデバイスの手放し(lease の印 + このサーバの記憶)。デバイス・ブリッジ・アプリには触らない。
// lease の再書き込みは call() が `holdsDeviceLease` で止める(止めないと応答の組み立てが印を書き直す)

import Foundation
import FTBridgeClient
import FTCore

extension MCPServer {

    /// 呼び出しの前後で lease の印を書く(進行中の印・markDeviceInUse)ツールか。**ft_release_device は書かない**
    static func holdsDeviceLease(_ tool: String) -> Bool {
        toolAcceptsDeviceTarget(tool) && tool != "ft_release_device"
    }

    /// `args` は call() が記憶した宛先を畳み込んだ後の引数。**ドライバを作らない・ブリッジへ問い合わせない**
    /// (止めた後に手放せなければ意味が無い)。鍵は udid / serial の明示 → 記録済みの解決結果の順
    func ftReleaseDevice(_ args: [String: Any]) async throws -> [[String: Any]] {
        let explicit = ((args["udid"] as? String) ?? (args["serial"] as? String)).flatMap { $0.isEmpty ? nil : $0 }
        guard let deviceKey = explicit ?? leaseDeviceKey(args: args) else {
            return text("Nothing to release: this session has not driven any device matching this target.")
        }
        // 鍵(udid / serial)を記録に持つセッションを全部手放す(同じ機がポート違いで複数あっても漏らさない)
        let sessionKeys = Set(sessions.compactMap { key, session -> String? in
            session.udid == .some(.some(deviceKey)) || session.connectedAndroidSerial == deviceKey ? key : nil
        })
        let hadState = sessionKeys.contains { sessions[$0] != nil }
        for key in sessionKeys { forgetConnection(key) }
        // 接続の記録を持たないまま残った「既定の宛先」の記憶(forgetConnection はポート / serial が一致したときだけ消す)
        if lastExplicitIOSTarget?.udid == deviceKey { lastExplicitIOSTarget = nil }
        for (port, udid) in seenExplicitIOSUDIDs where udid == deviceKey {
            seenExplicitIOSPorts.remove(port)
            seenExplicitIOSUDIDs[port] = nil
        }
        if lastExplicitAndroidSerial == deviceKey { lastExplicitAndroidSerial = nil }
        seenExplicitAndroidSerials.remove(deviceKey)

        let pid = ProcessInfo.processInfo.processIdentifier
        let removed = deviceLeaseStateDir.map { MCPDeviceLease.release(stateDir: $0, key: deviceKey, pid: pid) } ?? false
        let otherHolder = deviceLeaseStateDir.flatMap {
            MCPDeviceLease.holderPID(stateDir: $0, key: deviceKey, excluding: [pid])
        }
        return text(Self.releaseDeviceReply(deviceKey: deviceKey, removedLease: removed, forgotState: hadState,
                                            otherHolderPID: otherHolder))
    }

    /// 応答の文(純粋関数)。事実だけ: 何を手放したか・何に触っていないか・まだ別のセッションが持っているか
    static func releaseDeviceReply(deviceKey: String, removedLease: Bool, forgotState: Bool,
                                   otherHolderPID: Int32?) -> String {
        guard removedLease || forgotState else {
            return "Nothing to release: this session holds nothing on \(deviceKey)."
                + (otherHolderPID.map { " Another session (pid \($0)) does hold it." } ?? "")
        }
        var parts: [String] = []
        if removedLease { parts.append("hold mark removed") }
        if forgotState { parts.append("session state forgotten") }
        var reply = "Released \(deviceKey) (\(parts.joined(separator: ", "))). The bridge, the app and the device"
            + " were not touched."
        if let other = otherHolderPID {
            reply += " Another session (pid \(other)) still holds it, so `fleetest bridge down` keeps refusing until"
                + " that one lets go."
        } else {
            reply += " `fleetest bridge down` no longer sees this session as holding it."
        }
        return reply + " A later device tool call on it takes the hold again."
    }
}
