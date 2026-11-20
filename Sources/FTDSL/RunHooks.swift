// RunHooks.swift
// @RunHooks のクラスの beforeRun() / afterRun()(RR-8.4・DR-209)の実行時の側。呼ばれるのは `--run-hook before|after` の専用の子だけ。
// その子はドライバを持たない(NullDriver)ので、デバイスを操作するコマンドは perform / performCustom の入口で断る。

import Foundation
import FTCore

/// @RunHooks マクロが beforeRun() の呼び出しを包むために生成する(利用者が直接書くものではない)。
/// 失敗しても afterRun は別の子なので走る(呼び手の責務)
public func ftRunBeforeRun(_ body: () -> Void) {
    FTRuntime.requireCore(command: "beforeRun").runLifecycle("beforeRun", allowAfterFailure: true, body)
}

/// @RunHooks マクロが afterRun() の呼び出しを包むために生成する(利用者が直接書くものではない)
public func ftRunAfterRun(_ body: () -> Void) {
    FTRuntime.requireCore(command: "afterRun").runLifecycle("afterRun", allowAfterFailure: true, body)
}

extension FTDriveCore {
    /// beforeRun() / afterRun() を実行中か。判定は実行中のフェーズ(`currentSection`)で行う = ヘルパー関数を経由しても効く
    var inRunHook: Bool { currentSection == "beforeRun" || currentSection == "afterRun" }

    /// デバイスを操作しないコマンド(perform / performCustom を通るもの)。run メモ・httpRequest・data() / account() は
    /// そもそも通らない
    static let deviceFreeCommands: Set<String> = ["wait"]

    /// run フックの中でデバイスのコマンドを断る理由。断らないなら nil。`command` が無い呼び出しは説明の先頭語で名指しする
    static func runHookDeviceRefusal(command: String?, description: String, section: String?) -> String? {
        guard section == "beforeRun" || section == "afterRun" else { return nil }
        let name = command ?? String(description.split(separator: " ").first ?? "command")
        if deviceFreeCommands.contains(name) { return nil }
        return "\(section ?? "")() cannot use the device (\(name))"
    }

    /// perform / performCustom の入口から呼ぶ。断ったら失敗として記録して中断し、結果の status を返す
    func refuseDeviceCommandInRunHook(command: String?, description: String,
                                      file: String, line: Int) -> StepResult.Status? {
        guard let reason = Self.runHookDeviceRefusal(command: command, description: description,
                                                     section: currentSection) else { return nil }
        let status = StepResult.Status.failed(reason)
        recordStep(description: description, status: status, file: file, line: line, command: command)
        handleFailure(stepDescription: description, reason: reason)
        return status
    }
}
