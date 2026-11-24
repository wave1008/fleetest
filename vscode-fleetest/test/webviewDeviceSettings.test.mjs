// webviewDeviceSettings.test.mjs
// 設定タブ「デバイスモニター」の「実機をテストで使用する」(CLI 側のマシン設定 usePhysicalDevices)の往復テスト。
// **型検査の効かない境界**(webview ⇄ 拡張)なので、webview が送る形が拡張側の最終ゲート
// (isMonitorFromWebviewMessage)を通ることまで縛る。実 HTML+実バンドルで動かす方式は
// webviewRemoteHostsSettings.test.mjs と同じ。

import assert from "node:assert/strict";
import path from "node:path";
import { before, test } from "node:test";
import { createRequire } from "node:module";
import * as esbuild from "esbuild";
import { JSDOM } from "jsdom";
import { isMonitorFromWebviewMessage } from "../src/monitorModel";

const require2 = createRequire(import.meta.url);

let panelHtml;
let webviewBundle;

before(async () => {
  const htmlBuild = await esbuild.build({
    entryPoints: [path.resolve("src/monitorHtml.ts")],
    bundle: true,
    platform: "node",
    format: "cjs",
    target: "node18",
    write: false,
    external: ["vscode"],
    logLevel: "silent",
  });
  const vscodeStub = { Uri: { joinPath: (_base, ...segs) => ({ path: `/${segs.join("/")}` }) } };
  const patchedRequire = (id) => (id === "vscode" ? vscodeStub : require2(id));
  const mod = { exports: {} };
  new Function("module", "exports", "require", htmlBuild.outputFiles[0].text)(mod, mod.exports, patchedRequire);
  const webviewStub = { asWebviewUri: (uri) => `https://localhost${uri.path}`, cspSource: "https://localhost" };
  panelHtml = mod.exports.renderHtml(webviewStub, { path: "" });

  const mainBuild = await esbuild.build({
    entryPoints: [path.resolve("src/webview/monitor/main.js")],
    bundle: true,
    platform: "browser",
    format: "iife",
    target: "es2022",
    write: false,
    logLevel: "silent",
  });
  webviewBundle = mainBuild.outputFiles[0].text;
});

function createWebview(onPost = () => {}) {
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  window.acquireVsCodeApi = () => ({ postMessage: onPost, setState: () => {}, getState: () => undefined });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return { window, document: window.document };
}

function post(window, data) {
  window.dispatchEvent(new window.MessageEvent("message", { data }));
}

test("デバイスモニターのセクションで容量表示の下にあり、読めるまで押せない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  const box = document.getElementById("settings-use-physical-devices");
  assert.ok(box, "チェックボックスがある");
  const capacity = document.getElementById("settings-show-machine-capacity");
  assert.equal(box.closest(".settings-group"), capacity.closest(".settings-group"), "デバイスモニターのセクションにある");
  assert.equal(box.closest("label").previousElementSibling, capacity.closest("label"), "容量表示のすぐ下");
  assert.equal(box.checked, true, "既定は ON");
  assert.equal(box.disabled, true, "CLI の値が届くまで押せない");

  post(window, { type: "deviceSettings", usePhysicalDevices: false });
  assert.equal(box.checked, false);
  assert.equal(box.disabled, false);
});

test("切り替えは拡張側のゲートを通る形で送り、応答まで押せなくする", (t) => {
  const sent = [];
  const { window, document } = createWebview((m) => sent.push(m));
  t.after(() => window.close());

  const box = document.getElementById("settings-use-physical-devices");
  post(window, { type: "deviceSettings", usePhysicalDevices: true });
  box.checked = false;
  box.dispatchEvent(new window.Event("change", { bubbles: true }));

  const message = sent.find((m) => m.type === "setUsePhysicalDevices");
  assert.deepEqual({ ...message }, { type: "setUsePhysicalDevices", value: false });
  assert.ok(isMonitorFromWebviewMessage(message), "拡張側のゲートを通る");
  assert.equal(isMonitorFromWebviewMessage({ type: "setUsePhysicalDevices", value: "false" }), false);
  assert.equal(box.disabled, true);
});

test("書き込みの失敗は理由を出し、CLI の値へ戻す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  const box = document.getElementById("settings-use-physical-devices");
  const error = document.getElementById("settings-device-settings-error");
  post(window, { type: "deviceSettings", usePhysicalDevices: true, error: "boom" });
  assert.equal(box.checked, true);
  assert.equal(error.hidden, false);
  assert.equal(error.textContent, "boom");
  post(window, { type: "deviceSettings", usePhysicalDevices: true });
  assert.equal(error.hidden, true);
});

test("押した後の応答に値が無くても(読み直しも失敗)、押す前の値へ戻して押せる状態に戻す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  const box = document.getElementById("settings-use-physical-devices");
  post(window, { type: "deviceSettings", usePhysicalDevices: true });
  box.checked = false;
  box.dispatchEvent(new window.Event("change", { bubbles: true }));
  assert.equal(box.disabled, true);
  post(window, { type: "deviceSettings", error: "boom" });
  assert.equal(box.disabled, false, "固着しない");
  assert.equal(box.checked, true, "押す前の値へ戻る");
  assert.equal(document.getElementById("settings-device-settings-error").textContent, "boom");
});

test("一度も値が読めていない間の値の無い応答では、押せないまま", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const box = document.getElementById("settings-use-physical-devices");
  post(window, { type: "deviceSettings", error: "boom" });
  assert.equal(box.disabled, true);
});
