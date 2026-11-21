// RemoteDispatchPreparation.swift
// `run --runner` / `api run --runner` がリモートへ送る前に揃える共通の段(宛先の解決と告知・--tool-rev の確認・
// --align・送るデバイスの絞り込み)。各コマンドだけが断るフラグの検査は呼び手に残す。
// **`toStderr` は api run で true**(stdout は NDJSON 専用の契約。RemoteRunDispatcher.log の apiRun 分岐と同じ規律)

import ArgumentParser
import Foundation
import FTBridgeClient
import FTCore
import FTRemote

struct PreparedRemoteDispatch {
    let resolved: ResolvedRemoteHost
    let localRoot: URL
    let project: TestProject
    /// 向こうへ中継するデバイスの絞り込み(`--device-machine` 無しなら宛先の機械の枠へ絞った値)
    let devices: [String]
    let deviceMachine: String?
}

extension RunCommonOptions {
    /// `project` は宛先の告知の後に解く(run は告知 → project の順で断ってきた。打ち間違いが重なったときの文言を変えない)
    /// `overrides` は向こうの子へ中継する `--set`(送るデバイスの絞り込みも同じ上書きで決める)
    func prepareRemoteDispatch(_ dispatch: EffectiveDispatchTarget, profile: String,
                               overrides: [String: RunProfileSetValue], toStderr: Bool,
                               project resolveProject: () throws -> TestProject) throws -> PreparedRemoteDispatch {
        let resolved = try resolveRemoteTarget(dispatch, remoteDirOverride: remoteDir)
        resolved.announce(toStderr: toStderr)
        let project = try resolveProject()
        let localRoot = try RepoRoot.find()
        try rejectUnresolvableToolRev(repoRoot: localRoot)
        // `--align`: 宛先を手元(`--tool-rev` があればその版)へ揃えてから、今のディスパッチの経路へ進む
        // (照合が揃えた結果を確かめる)
        if align {
            _ = try RemoteAlign.execute(resolved: resolved, repoRoot: localRoot, toolRev: toolRev,
                                        guarded: true, io: toStderr ? .stderr : .stdout)
        }
        var scopedDevices = devices
        var scopedDeviceMachine = deviceMachine
        if deviceMachine == nil {
            (scopedDevices, scopedDeviceMachine) = try machineScopedDeviceFilter(
                project: project, profile: profile, targetMachine: dispatch.rawTarget,
                requestedDevices: devices, overrides: overrides)
        } else if let deviceMachine {
            try rejectDisabledNamedDevices(project: project, profile: profile, deviceMachine: deviceMachine,
                                           devices: devices, overrides: overrides)
        }
        return PreparedRemoteDispatch(resolved: resolved, localRoot: localRoot, project: project,
                                      devices: scopedDevices, deviceMachine: scopedDeviceMachine)
    }
}

extension RemoteDispatchFlagPolicy.Decision {
    /// 注記は呼び手の出力先へ(run は stdout・api run は stderr)。拒否は ValidationError
    func apply(note: (String) -> Void) throws {
        switch self {
        case .allowed:
            return
        case .ignoredWithNote(let message):
            note(message)
        case .rejected(let message):
            throw ValidationError(message)
        }
    }
}
