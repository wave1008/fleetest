// RunnerCloneProjectCheck.swift
// `RunnerCloneProjectGuard` の I/O 側。呼び手: `fleetest run`(Fleetest.swift)・`api run`(ApiRunCommand.swift)・
// `DeviceRosterLoad.load(project: String?, ...)`(デバイスに触る devices / api start-* / stop-* / restart)。
// 呼ばない: MCP(ft_* は利用者のデバイスを直接指す・プロファイルの machine を解釈しない)・monitor / device-stream(観測だけ)・
// dry-run(デバイスに触れず、ロックも取らない)。

import ArgumentParser
import FTBridgeClient
import FTCore
import Foundation

enum RunnerCloneProjectCheck {

    /// `deviceMachine`: 呼び手が明示した `--device-machine`(手元以外ならランナー視点の正しい選び方)。
    /// `explicitLocalRunner`: `run` / `api run` に `--runner local` が明示されたか(デバイスの操作には無い口 = false)。既定値を置かない
    static func rejectIfRunnerClone(project: TestProject, deviceMachine: String?, explicitLocalRunner: Bool) throws {
        guard let toolRoot = try? RepoRoot.find() else { return }
        let hasMarker = FileManager.default.fileExists(
            atPath: toolRoot.appendingPathComponent(RunnerCloneProjectGuard.markerRelativePath).path)
        // 印の無い機械(発行側・受け手の通常の構成)ではプロファイルを読まない
        guard hasMarker else { return }
        let inside = RunnerCloneProjectGuard.isInsideCloneProjects(projectRoot: project.rootURL, toolRoot: toolRoot)
        guard inside else { return }
        let message = RunnerCloneProjectGuard.refusal(
            hasMarker: hasMarker, projectInsideClone: inside,
            machineAnnotated: RunnerProfileView.isMachineAnnotated(runProfiles: runProfiles(of: project)),
            explicitMachineChoice: MachineDispatch.normalize(deviceMachine) != nil || explicitLocalRunner)
        if let message { throw ValidationError(message) }
    }

    private static func runProfiles(of project: TestProject) -> [[String: Any]] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: project.runsDir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = try? Data(contentsOf: project.runsDir.appendingPathComponent(name)) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }
}
