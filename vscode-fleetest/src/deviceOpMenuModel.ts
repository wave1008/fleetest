// deviceOpMenuModel.ts
// タイル右クリックメニューの唯一の項目(起動/停止/実行中表示)を決める純粋関数。定義はここだけ。
// **拡張と webview の両バンドルに入る**(src/webview/monitor/deviceTiles.js が import する)ので vscode を
// 引き込む import を足さない。表示文字列ではなく webview 辞書のキーを返す(webview の t は import 時に
// document を読むので node のテストから呼べない。訳すのは呼び手 = deviceTiles.js)。

import type { MonitorDeviceState } from "./monitorDeviceModel";
import type { DeviceOpKind, DeviceOpQueueStatus } from "./monitorDeviceLifecycle";
import type { webviewMonitorAStrings } from "./i18n/strings/webviewMonitorA";

export type DeviceOpMenuLabelKey = Extract<keyof typeof webviewMonitorAStrings, `wvMonitor.deviceOpMenu.${string}`>;

/** タイルで実行中/待機中の操作。cancellable は「起動中・起動待ちの1台」だけ(一括起動・再起動のバッチには無い)。 */
export interface DeviceOpMenuBusy {
  readonly op: DeviceOpKind;
  readonly status: DeviceOpQueueStatus;
  readonly cancellable?: boolean;
}

export interface DeviceOpMenuItem {
  readonly labelKey: DeviceOpMenuLabelKey;
  /** クリック時に実行する操作(disabled:true の間はクリック不可)。cancelUp = 起動の取り消し(MonitorDeviceOps.cancelDeviceUp) */
  readonly op: DeviceOpKind | "cancelUp";
  readonly disabled: boolean;
}

/**
 * physical: 実機は端末そのものを起動・停止しない(DeviceBooter の実機分岐)。操作対象は**ブリッジだけ**なので
 * ラベルで明示する(「起動/停止」だと端末の電源だと誤解される)。項目自体は隠さない: 隠すとモニターから実機の
 * ブリッジを起動できなくなる(タイルが「接続中」のまま何もできない状態になる実害)。
 * MonitorDeviceState の全パターンをカバーするため戻り値は null にならない。
 */
export function deviceOpMenuItem(
  state: MonitorDeviceState,
  busy: DeviceOpMenuBusy | undefined,
  physical: boolean,
): DeviceOpMenuItem {
  if (busy?.op === "up" && busy.cancellable === true) {
    return { labelKey: "wvMonitor.deviceOpMenu.cancelStart", op: "cancelUp", disabled: false };
  }
  if (busy?.status === "queued") {
    return { labelKey: "wvMonitor.deviceOpMenu.queued", op: busy.op, disabled: true };
  }
  if (busy?.op === "up") {
    return { labelKey: "wvMonitor.deviceOpMenu.startingUp", op: "up", disabled: true };
  }
  if (busy?.op === "down") {
    return { labelKey: "wvMonitor.deviceOpMenu.stoppingDown", op: "down", disabled: true };
  }
  if (busy?.op === "wipe") {
    return { labelKey: "wvMonitor.deviceOpMenu.wiping", op: "wipe", disabled: true };
  }
  // restartBridge は自動修復専用(monitorBridgeLogRotation.ts)でタイル右クリックからは撃てない。
  // 進行中に「起動/停止」を出すと二重操作の入口になるため busy 表示だけ足す
  if (busy?.op === "restartBridge") {
    return { labelKey: "wvMonitor.deviceOpMenu.restartingBridge", op: "restartBridge", disabled: true };
  }
  // unknown(リモートで観測できていない)は「起動」を出す —— 止めようがない状態で「停止」を
  // 出すより、起動を撃てるほうが役に立つ(起動は fan-out でその機械へ届く)
  if (state === "offline" || state === "unknown") {
    return {
      labelKey: physical ? "wvMonitor.deviceOpMenu.startBridge" : "wvMonitor.deviceOpMenu.start",
      op: "up",
      disabled: false,
    };
  }
  return {
    labelKey: physical ? "wvMonitor.deviceOpMenu.stopBridge" : "wvMonitor.deviceOpMenu.stop",
    op: "down",
    disabled: false,
  };
}
