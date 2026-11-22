// scenarioVariant.test.mjs
// バリアント(同じシナリオを外観・文字サイズ違いで回す)の拡張側の受け口: 状態の鍵(ID / ID@variant)・
// 表示名・失敗メッセージ・last-results の variants ディレクトリの除外・結果の書き出しの列。
// variant の無い run が今までと同じ形であることも見る。

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import zlib from "node:zlib";
import { readAllResults } from "../src/lastResults";
import { buildResultsExportModel, extractResultsExportScenarioSource } from "../src/resultsExportModel";
import { buildResultsExportWorkbook } from "../src/resultsExportWorkbook";
import { createRunLaneState, isAnyLaneRunning, reduceLaneEvent } from "../src/runLaneModel";
import { createRunReducerState, reduceRunEvent } from "../src/runReducer";
import { failureMessageText, scenarioUnitKey, scenarioUnitLabel } from "../src/scenarioUnitKey";

function feed(events, nowOf) {
  const state = createRunReducerState();
  const actions = [];
  events.forEach((event, i) => actions.push(...reduceRunEvent(state, event, nowOf(i)).actions));
  return { state, actions };
}

test("scenarioUnitKey / Label: variant 無しは ID のまま、有りは ID@variant / ID [variant]", () => {
  assert.equal(scenarioUnitKey("S0010"), "S0010");
  assert.equal(scenarioUnitKey("S0010", undefined), "S0010");
  assert.equal(scenarioUnitKey("S0010", "dark"), "S0010@dark");
  assert.equal(scenarioUnitLabel("S0010", "dark"), "S0010 [dark]");
  assert.equal(scenarioUnitLabel("S0010"), "S0010");
  assert.equal(failureMessageText("x", "dark"), "[dark] x");
  assert.equal(failureMessageText("x"), "x");
});

test("runReducer: 同じ ID の2バリアントが同時に走っても経過・失敗が混ざらない", () => {
  const times = [100, 200, 300, 1000, 2000];
  const { state, actions } = feed(
    [
      { kind: "scenarioStarted", scenario: "S1", variant: "light", worker: "a" },
      { kind: "scenarioStarted", scenario: "S1", variant: "dark", worker: "b" },
      { kind: "step", scenario: "S1", variant: "dark", status: "failed", description: "tap", detail: "boom" },
      { kind: "scenarioFinished", scenario: "S1", variant: "light", passed: true, worker: "a" },
      { kind: "scenarioFinished", scenario: "S1", variant: "dark", passed: false, worker: "b" },
    ],
    (i) => times[i],
  );
  assert.equal(state.scenarios.size, 0);
  const passed = actions.find((a) => a.type === "passed");
  assert.equal(passed.variant, "light");
  assert.equal(passed.durationMs, 1000 - 100); // light の開始(100)から。dark の開始(200)に化けない
  const failed = actions.find((a) => a.type === "failed");
  assert.equal(failed.variant, "dark");
  assert.equal(failed.durationMs, 2000 - 200);
  assert.equal(failed.messages.length, 1); // light の終わりが dark の失敗を消していない
  assert.match(failed.messages[0].text, /boom/);
  const started = actions.filter((a) => a.type === "output" && a.text.startsWith("▶"));
  assert.deepEqual(started.map((a) => a.text), ["▶ S1 [light]", "▶ S1 [dark]"]);
});

test("runReducer: variant 無しの run のアクションに variant の欄は現れない", () => {
  const { actions } = feed(
    [
      { kind: "scenarioStarted", scenario: "S1" },
      { kind: "scenarioFinished", scenario: "S1", passed: true },
    ],
    () => 0,
  );
  for (const action of actions) {
    assert.equal("variant" in action, false);
  }
  assert.equal(actions[1].text, "▶ S1");
});

test("runLaneModel: scenarioTimings は単位の鍵で持ち、片方の終わりが他方の経過を消さない", () => {
  const state = createRunLaneState();
  reduceLaneEvent(state, { kind: "scenarioStarted", scenario: "S1", variant: "light", worker: "a" }, 100);
  reduceLaneEvent(state, { kind: "scenarioStarted", scenario: "S1", variant: "dark", worker: "b" }, 200);
  assert.deepEqual([...state.scenarioTimings.keys()].sort(), ["S1@dark", "S1@light"]);
  reduceLaneEvent(state, { kind: "scenarioFinished", scenario: "S1", variant: "light", passed: true, worker: "a" }, 500);
  assert.deepEqual([...state.scenarioTimings.keys()], ["S1@dark"]);
  assert.equal(isAnyLaneRunning(state), true);
  const actions = reduceLaneEvent(state, { kind: "scenarioFinished", scenario: "S1", variant: "dark", passed: true, worker: "b" }, 700);
  assert.ok(actions.some((a) => a.type === "line" && String(a.text ?? a.line ?? "").includes("(500ms)")) ||
    JSON.stringify(actions).includes("(500ms)"));
  assert.equal(state.scenarioTimings.size, 0);
});

test("runLaneModel: variant 無しの鍵は ID のまま", () => {
  const state = createRunLaneState();
  reduceLaneEvent(state, { kind: "scenarioStarted", scenario: "S1", worker: "a" }, 100);
  assert.deepEqual([...state.scenarioTimings.keys()], ["S1"]);
});

test("lastResults: variants ディレクトリをシナリオ ID と読み違えない", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ft-last-"));
  try {
    const prof = path.join(dir, "p1");
    fs.mkdirSync(path.join(prof, "variants", "dark"), { recursive: true });
    fs.writeFileSync(path.join(prof, "S0010"), "failed");
    fs.writeFileSync(path.join(prof, "variants", "dark", "S0010"), "failed");
    // ディレクトリ名と同名の ID は無いが、読めてしまう形(中身が passed のファイル)が混ざっても拾わない
    fs.writeFileSync(path.join(prof, "variants", "dark", "S0011"), "passed");
    const results = readAllResults(dir);
    assert.deepEqual([...results.entries()], [["S0010", "failed"]]);
    assert.equal(results.has("variants"), false);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

function readZip(buffer) {
  const eocd = buffer.subarray(buffer.length - 22);
  const total = eocd.readUInt16LE(10);
  let offset = eocd.readUInt32LE(16);
  const files = new Map();
  for (let i = 0; i < total; i++) {
    const compressedSize = buffer.readUInt32LE(offset + 20);
    const nameLen = buffer.readUInt16LE(offset + 28);
    const extraLen = buffer.readUInt16LE(offset + 30);
    const commentLen = buffer.readUInt16LE(offset + 32);
    const local = buffer.readUInt32LE(offset + 42);
    const name = buffer.subarray(offset + 46, offset + 46 + nameLen).toString("utf8");
    const start = local + 30 + buffer.readUInt16LE(local + 26) + buffer.readUInt16LE(local + 28);
    files.set(name, zlib.inflateRawSync(buffer.subarray(start, start + compressedSize)).toString("utf8"));
    offset += 46 + nameLen + extraLen + commentLen;
  }
  return files;
}

function sourceRaw(extra = {}) {
  return { scenarioID: "C.S1", platform: "ios", passed: true, durationMs: 1000, startedAt: "2026-09-20T00:00:00.000Z", ...extra };
}

function scenariosSheet(raws) {
  const sources = raws.map((r) => extractResultsExportScenarioSource(r, null, null));
  const model = buildResultsExportModel("P", sources, []);
  return { model, xml: readZip(buildResultsExportWorkbook(model).toBuffer()).get("xl/worksheets/sheet2.xml") };
}

test("結果の書き出し: variant があるときだけ末尾にバリアントの列が付く", () => {
  const { model, xml } = scenariosSheet([sourceRaw({ variant: "dark" }), sourceRaw({ scenarioID: "C.S2", variant: "light" })]);
  assert.deepEqual(model.scenarios.map((r) => r.variant).sort(), ["dark", "light"]);
  assert.match(xml, /<autoFilter ref="A1:Q3"\/>/);
  assert.match(xml, /<c r="Q1"/);
});

test("結果の書き出し: variant の無い run は列を足さない(autoFilter は A1:P)", () => {
  const { model, xml } = scenariosSheet([sourceRaw(), sourceRaw({ scenarioID: "C.S2" })]);
  assert.equal(model.scenarios.every((r) => r.variant === null), true);
  assert.match(xml, /<autoFilter ref="A1:P3"\/>/);
  assert.doesNotMatch(xml, /<c r="Q1"/);
});
