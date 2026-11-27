// `fleetest api device-traits`: この機械の台の性質(`DeviceTraits`)を JSON `{ "<デバイス名>": DeviceTraits }` で出す。
// 親が別の機械の台の観測を remote exec で引くための内部口(拡張は使わない)。何も起動しない・ブリッジに触らない。

import ArgumentParser
import Foundation
import FTCore

struct ApiDeviceTraitsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device-traits",
        abstract: "Print the observed traits of this machine's profile devices as JSON on stdout"
            + " (foldable, home button, OS version, model; null = unreadable). Starts nothing",
        shouldDisplay: false)

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Run profile name")
    var profile: String

    @Option(help: "Registered machine name whose devices are observed here (omit for the devices with no machine)")
    var machine: String?

    func run() async throws {
        let testProject = try ScenarioHost.project(named: project)
        let wanted = MachineDispatch.normalize(machine)
        let entries = ProfileResolver.runDeviceEntries(project: testProject, runProfileName: profile)
            .filter { MachineDispatch.normalize($0.machine) == wanted }
        let traits = DeviceTraitsObserver.observe(entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        ConsoleOut.out(String(data: try encoder.encode(traits), encoding: .utf8)!)
    }
}
