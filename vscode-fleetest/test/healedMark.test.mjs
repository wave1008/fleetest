// healedMark.test.mjs
// healedMark.ts(Test Explorer の「自己修復で成功」の印の付け外し)のユニットテスト。

import assert from "node:assert/strict";
import { test } from "node:test";
import { descriptionOnPassed, descriptionOnStarted } from "../src/healedMark";
import { laneStrings, setLaneLocale } from "../src/i18n/strings/lane";

const mark = laneStrings["lane.healedDescription"];

test("descriptionOnPassed: 自己修復したステップがあり表示が空なら印を付ける・無ければ付けない", (t) => {
  t.after(() => setLaneLocale("ja"));
  setLaneLocale("ja");
  assert.equal(descriptionOnPassed(undefined, 1), mark.ja);
  assert.equal(descriptionOnPassed("", 2), mark.ja);
  assert.equal(descriptionOnPassed(undefined, 0), undefined);
  setLaneLocale("en");
  assert.equal(descriptionOnPassed(undefined, 1), mark.en);
});

test("descriptionOnPassed: 削除中・下書きの表示は上書きしない", () => {
  assert.equal(descriptionOnPassed("下書き", 3), "下書き");
});

test("descriptionOnStarted: 自分の印だけ外す(日英どちらの印も)", () => {
  assert.equal(descriptionOnStarted(mark.ja), undefined);
  assert.equal(descriptionOnStarted(mark.en), undefined);
  assert.equal(descriptionOnStarted(undefined), undefined);
});

test("descriptionOnStarted: 他の表示は残す", () => {
  assert.equal(descriptionOnStarted("下書き"), "下書き");
  assert.equal(descriptionOnStarted("🔧 something else"), "🔧 something else");
});
