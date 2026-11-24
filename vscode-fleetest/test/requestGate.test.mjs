// requestGate.js(応答に要求 id が無い deviceCatalog / installedDevices の対応付け)の単体テスト。
import assert from "node:assert/strict";
import path from "node:path";
import { test } from "node:test";
import * as esbuild from "esbuild";

async function load() {
  const out = await esbuild.build({
    entryPoints: [path.resolve("src/webview/monitor/requestGate.js")],
    bundle: true, platform: "node", format: "esm", write: false, logLevel: "silent",
  });
  return import(`data:text/javascript;base64,${Buffer.from(out.outputFiles[0].text).toString("base64")}`);
}

test("閉じている間に飛んでいた要求の応答は捨て、控えた要求をその後で撃つ", async () => {
  const { createRequestGate, gateSend, gateClose, gateReceive } = await load();
  const gate = createRequestGate();
  const sent = [];
  gateSend(gate, () => sent.push("A"));
  gateClose(gate);
  gateSend(gate, () => sent.push("B"));
  assert.deepEqual(sent, ["A"], "古い要求の応答が来るまで撃たない");
  assert.equal(gateReceive(gate), false, "古い応答は捨てる");
  assert.deepEqual(sent, ["A", "B"]);
  assert.equal(gateReceive(gate), true, "次の応答は描く");
});

test("要求なしで届いた応答・閉じていない要求の応答は描く", async () => {
  const { createRequestGate, gateSend, gateReceive } = await load();
  const gate = createRequestGate();
  assert.equal(gateReceive(gate), true);
  gateSend(gate, () => {});
  assert.equal(gateReceive(gate), true);
});
