// deviceSettingsController.ts
// 設定タブ「実機をテストで使用する」の CLI 越しの読み書き。正は CLI 側のマシン設定(usePhysicalDevices)で、
// 拡張は値を保持しない(retentionController.ts と同じ原則)。
//
// 契約(CLI 側と並行実装。Sources/fleetest/ApiDeviceSettingsCommand.swift):
//   fleetest api device-settings                                  → {"usePhysicalDevices":true}
//   fleetest api device-settings --use-physical-devices <bool>    → 同じ形(書いた後の実効値)
// 失敗(非ゼロ終了・形の違う出力)は error に畳んで返す。

import { runOneShot } from "./oneShotCli";
import type { RetentionCliDeps } from "./retentionController";

export interface DeviceSettingsOutcome {
  readonly usePhysicalDevices?: boolean;
  readonly error?: string;
}

async function run(deps: RetentionCliDeps, args: readonly string[]): Promise<DeviceSettingsOutcome> {
  let result: Awaited<ReturnType<typeof runOneShot>>;
  try {
    result = await runOneShot(deps.getConfig().binaryPath, deps.workspaceRoot, [...args], deps.outputChannel,
      deps.registerChild);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    deps.outputChannel.appendLine(`[device-settings] ${args.join(" ")}: ${message}`);
    return { error: message };
  }
  if (result.exitCode !== 0) {
    deps.outputChannel.appendLine(
      `[device-settings] ${args.join(" ")} failed (exit ${String(result.exitCode)}): ${result.stderrTail}`,
    );
    const message = result.stderrTail.trim();
    return { error: message.length > 0 ? message : `exit ${String(result.exitCode)}` };
  }
  return parseDeviceSettings(result.json) ?? { error: "unexpected output shape" };
}

export function parseDeviceSettings(json: unknown): DeviceSettingsOutcome | undefined {
  if (typeof json !== "object" || json === null) {
    return undefined;
  }
  const value = (json as { usePhysicalDevices?: unknown }).usePhysicalDevices;
  return typeof value === "boolean" ? { usePhysicalDevices: value } : undefined;
}

export function fetchDeviceSettings(deps: RetentionCliDeps): Promise<DeviceSettingsOutcome> {
  return run(deps, ["api", "device-settings"]);
}

export function updateDeviceSettings(deps: RetentionCliDeps, value: boolean): Promise<DeviceSettingsOutcome> {
  return run(deps, ["api", "device-settings", "--use-physical-devices", String(value)]);
}
