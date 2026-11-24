// VSCode拡張向け: 設定タブ「デバイスモニター」の「実機をテストで使用する」(LocalConfig.usePhysicalDevices)の読み書き
// (fleetest api device-settings)。stdout には結果 1 行の JSON だけを出す(診断は stderr のみ。
// ApiRetentionCommand.swift と同じ流儀)。
//
// **拡張側と1:1の契約**: `{"usePhysicalDevices": Bool}`(常に実効値。未設定 = true)。
// 対向: vscode-fleetest/src/deviceSettingsController.ts

import ArgumentParser
import Foundation
import FTCore

struct ApiDeviceSettingsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device-settings",
        abstract: "Read or update the device settings (~/.config/fleetest/config.json) and print them"
            + " as JSON on stdout (diagnostics on stderr only)")

    @Option(name: .customLong("use-physical-devices"),
            help: "Show physical devices in the device monitor (true/false), then print the result")
    var usePhysicalDevices: Bool?

    func run() async throws {
        var config = try usePhysicalDevices != nil ? LocalConfig.loadForUpdate() : LocalConfig.load()
        if let usePhysicalDevices {
            Self.apply(usePhysicalDevices: usePhysicalDevices, to: &config)
            try config.save()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        ConsoleOut.out(String(decoding: try encoder.encode(Output(config)), as: UTF8.self))
    }

    /// 保存するのは false だけ(既定へ戻すときは欄ごと消す。`localMachineEnabled` と同じ)
    static func apply(usePhysicalDevices: Bool, to config: inout LocalConfig) {
        config.usePhysicalDevices = usePhysicalDevices ? nil : false
    }

    struct Output: Encodable {
        let usePhysicalDevices: Bool
        init(_ config: LocalConfig) { usePhysicalDevices = config.usePhysicalDevices != false }
    }
}
