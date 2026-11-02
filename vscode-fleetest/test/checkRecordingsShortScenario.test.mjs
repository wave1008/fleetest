// Scripts/check-recordings.py の (b): クリップが無い記録は、切り出しの下限(500ms。VideoRecordingCoordinator.makeClips)未満の
// 短いシナリオだけ許す。クリップ数 == シナリオ数で比べると、148〜412ms のシナリオの回が赤になる。
// 逆向き(下限以上なのにクリップが無い・クリップが記録より多い)は不一致のまま。

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import path from "node:path";
import { test } from "node:test";

const ROOT = path.join(process.cwd(), "..");
const SCRIPT = path.join(ROOT, "Scripts/check-recordings.py");

function problems(recordings, scenarios) {
  const code = [
    "import importlib.util, json, sys",
    `spec = importlib.util.spec_from_file_location('cr', ${JSON.stringify(SCRIPT)})`,
    "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)",
    "data = json.loads(sys.stdin.read())",
    "print(json.dumps(m.unexplained_missing_clips(data['recordings'], data['scenarios'])))",
  ].join("\n");
  const out = execFileSync("python3", ["-I", "-c", code], {
    input: JSON.stringify({ recordings, scenarios }), encoding: "utf8",
  });
  return JSON.parse(out);
}

const clip = (id) => ({ scenarioID: id });
const rec = (id, ms) => ({ scenarioID: id, durationMs: ms });

test("下限未満の短いシナリオにクリップが無いのは整合", () => {
  assert.deepEqual(problems([clip("A.x")], { "A.x": [rec("A.x", 3000)], "A.short": [rec("A.short", 412)] }), []);
});

test("下限以上のシナリオにクリップが無いのは不一致", () => {
  const got = problems([], { "A.long": [rec("A.long", 500)] });
  assert.equal(got.length, 1);
});

test("クリップが記録より多いのは不一致", () => {
  assert.equal(problems([clip("A.x"), clip("A.x")], { "A.x": [rec("A.x", 3000)] }).length, 1);
});

test("同じ ID の記録が複数あるとき、長い記録にクリップを割り当てる", () => {
  assert.deepEqual(problems([clip("A.x")], { "A.x": [rec("A.x", 200), rec("A.x", 4000)] }), []);
  assert.equal(problems([clip("A.x")], { "A.x": [rec("A.x", 900), rec("A.x", 4000)] }).length, 1);
});
