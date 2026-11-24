// コードレビュー(b7)で挙がった欠陥の直しの回帰テスト。純粋関数は実体を、配線(vscode 依存で実体を作れない部分)は
// ソース走査で守る。走査はコメント行を落としてから見る(理由書きに関数名が出るので、実装を消しても緑になるのを防ぐ)。

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { commandContainsPath } from "../src/residentProcesses";
import { exitCodeForExited } from "../src/debugAdapter";
import { Utf8LineSplitter, Utf8Text } from "../src/utf8Chunks";

const root = process.cwd();

function code(rel) {
  return fs
    .readFileSync(path.join(root, rel), "utf8")
    .split("\n")
    .filter((line) => !/^\s*(\/\/|\*|\/\*)/.test(line))
    .join("\n");
}

function body(source, marker) {
  const start = source.indexOf(marker);
  assert.notEqual(start, -1, `${marker} が見つからない`);
  const end = source.indexOf("\n  }\n", start);
  return source.slice(start, end === -1 ? undefined : end);
}

// ---- isWorkspaceOwned のパス境界 ----
// 変異: 区切りを見ない `command.includes(dir)` に戻す → 兄弟フォルダのケースが落ちる。常に true → 全部の「当たらない」が落ちる

test("commandContainsPath: 名前の続く別フォルダ・別の親の下の同名には当たらない", () => {
  const ws = "/x/fleetest";
  assert.equal(commandContainsPath("/x/fleetest-runner/.build/debug/fleetest run", ws), false);
  assert.equal(commandContainsPath("/x/fleetest2/bin/fleetest api monitor", ws), false);
  assert.equal(commandContainsPath("/y/x/fleetest/bin/fleetest run", ws), false);
});

test("commandContainsPath: 配下・引数・引用符つきには当たる", () => {
  const ws = "/x/fleetest";
  assert.equal(commandContainsPath("/x/fleetest/.build/debug/fleetest run", ws), true);
  assert.equal(commandContainsPath("xcodebuild -xctestrun /x/fleetest/.fleetest/a.xctestrun", ws), true);
  assert.equal(commandContainsPath("node --cwd=/x/fleetest run", ws), true);
  assert.equal(commandContainsPath('fleetest --project "/x/fleetest"', ws), true);
  assert.equal(commandContainsPath("fleetest -C /x/fleetest", ws), true);
  assert.equal(commandContainsPath("/x/fleetest-runner/a /x/fleetest/b", ws), true, "2つ目の出現で当たる");
  assert.equal(commandContainsPath("/x/fleetest/bin/f", "/x/fleetest/"), true, "末尾の区切りは無視する");
  assert.equal(commandContainsPath("/anything", "/"), false, "ルートは当てない");
});

// ---- UTF-8 の連結 ----
// 変異: push で chunk.toString("utf8") を足していく実装に戻す → 分断されたマルチバイトが U+FFFD になり落ちる

const SAMPLE = "日本語😀のJSON\nつぎの行";

function splitInside(buffer, charStart) {
  // 日本語の1文字(3バイト)・絵文字(4バイト)の途中で切る
  return [buffer.subarray(0, charStart + 1), buffer.subarray(charStart + 1)];
}

test("Utf8Text: マルチバイト文字がチャンク境界で分断されても化けない", () => {
  const bytes = Buffer.from(SAMPLE, "utf8");
  for (let at = 1; at < bytes.length; at += 1) {
    const text = new Utf8Text();
    text.push(bytes.subarray(0, at));
    text.push(bytes.subarray(at));
    assert.equal(text.text(), SAMPLE, `${at} バイト目で分断`);
  }
});

test("Utf8LineSplitter: 分断された文字を含む行も、改行で確定した時点で正しく取り出す。末尾は rest()", () => {
  const bytes = Buffer.from(SAMPLE, "utf8");
  for (let at = 1; at < bytes.length; at += 1) {
    const splitter = new Utf8LineSplitter();
    const lines = [...splitter.push(bytes.subarray(0, at)), ...splitter.push(bytes.subarray(at))];
    assert.deepEqual(lines, ["日本語😀のJSON"], `${at} バイト目で分断`);
    assert.equal(splitter.rest(), "つぎの行");
    assert.equal(splitter.rest(), "", "rest() の後は空");
  }
  const [a, b] = splitInside(Buffer.from("あ\r\n", "utf8"), 0);
  const crlf = new Utf8LineSplitter();
  assert.deepEqual([...crlf.push(a), ...crlf.push(b)], ["あ"], "CRLF の CR は落とす");
});

test("出力を読む口は、チャンクごとの toString(utf8) の連結を使わない", () => {
  for (const rel of [
    "src/monitorDeviceOps.ts",
    "src/monitorUpdateController.ts",
    "src/runHandler.ts",
    "src/deviceStream.ts",
    "src/monitorPanel.ts",
  ]) {
    const source = code(rel);
    assert.ok(!/\b(stdout|stderr|stderrTail|pending|partial)\s*\+=\s*[\w.()]*chunk\.toString\("utf8"\)/.test(source),
      `${rel}: チャンクごとの文字列連結が残っている`);
    assert.ok(!/(partial|pending)\s*\+\s*chunk\.toString/.test(source), `${rel}: partial + chunk.toString が残っている`);
  }
});

// ---- 「全て終了して閉じる」前の serve 畳み ----
// 変異: suspendServeForSweep の行を消す / bridge down の後ろへ動かす → 落ちる

test("killResidentProcessesCore は bridge down --all の前に自分のライブ操作の serve を畳む", () => {
  const fn = body(code("src/monitorPanel.ts"), "private async killResidentProcessesCore(): Promise<void> {");
  const suspend = fn.indexOf("await this.live.suspendServeForSweep()");
  const down = fn.indexOf('"bridge", "down", "--all"');
  assert.ok(suspend >= 0 && down > suspend, "畳む(await)のが bridge down --all より前");
});

// ---- adoptPanel の配信の表示状態 ----
// 変異: adoptPanel の applyDeviceStreamVisibility() を消す → 落ちる

test("adoptPanel は引き取ったパネルの表示状態を配信へ当てる", () => {
  const fn = body(code("src/monitorPanel.ts"), "private adoptPanel(");
  assert.match(fn, /this\.panelVisible = panel\.visible/);
  assert.match(fn, /this\.pendingInitialTab = initialTab;\s*this\.applyDeviceStreamVisibility\(\);/,
    "リスナー内でなく adoptPanel 本体で当てる(作成時は onDidChangeViewState が発火しない)");
});

// ---- 中断の口 ----
// 変異: rerunFailed の add を消す / run.token の購読を消す / align の cancellable を false に戻す → 落ちる

test("fleetest.rerunFailedTests は中断の口(programmaticRunCancelSources)に登録する", () => {
  const source = code("src/runHandler.ts");
  const at = source.indexOf('"fleetest.rerunFailedTests"');
  const fn = source.slice(at, source.indexOf('"fleetest.copyTestName"', at));
  assert.match(fn, /programmaticRunCancelSources\.add\(tokenSource\)/);
  assert.match(fn, /programmaticRunCancelSources\.delete\(tokenSource\)/);
});

test("executeRun / executeDebugRun は run.token(Test Explorer の停止ボタンが取り消す側)も購読する", () => {
  const source = code("src/runHandler.ts");
  const run = source.slice(source.indexOf("async function executeRun("), source.indexOf("async function executeDebugRun("));
  assert.match(run, /run\.token\.onCancellationRequested\(cancelInvocation\)/);
  assert.match(run, /runTokenListener\.dispose\(\)/);
  const debug = source.slice(source.indexOf("async function executeDebugRun("));
  assert.match(debug, /run\.token\.onCancellationRequested\(stopSession\)/);
  assert.match(debug, /startDebugging\(workspaceFolder, debugConfig\)[\s\S]*?cancelRequested\(\)\) \{\s*stopSession\(\)/,
    "startDebugging の後で、開始前に取り消されていた分を拾う");
});

test("align は中断できる(cancellable・token から SIGTERM・時限 SIGKILL はしない)", () => {
  const source = code("src/runHandler.ts");
  const align = source.slice(source.indexOf("function runRemoteAlign("), source.indexOf("async function executeRun("));
  assert.match(align, /proc\.kill\("SIGTERM"\)/);
  assert.ok(!align.includes("SIGKILL"), "fleetest の子なので時限 SIGKILL しない");
  assert.match(source, /alignProgressTitle"\),\s*cancellable: true/);
  assert.match(source, /runRemoteAlign\(\s*config\.binaryPath, workspaceRoot, hostName, outputChannel, \[progressToken, token, run\.token\]/);
});

// ---- stopping の印は子ごと ----
// 変異: WeakSet を機械/コントローラ単位のフラグへ戻す → 落ちる

test("host-metrics / serve の「意図した停止」は子ごとの WeakSet", () => {
  const pm = code("src/monitorProcessManager.ts");
  assert.match(pm, /stoppingHostMetrics = new WeakSet<MonitorProcess>\(\)/);
  assert.ok(!/child\.stopping\b/.test(pm), "共有の1フラグが残っている");
  const live = code("src/monitorLiveController.ts");
  assert.match(live, /stoppingServe = new WeakSet<ServeProcess>\(\)/);
  assert.ok(!/this\.stoppingServe\s*=\s*(true|false)/.test(live), "共有の1フラグが残っている");
});

// ---- DAP ----
// 変異: 順序を terminated → exited に戻す(dap.test.mjs が落ちる)/ signal を無視する(下が落ちる)

test("exitCodeForExited: シグナルで死んだ子は 128+番号、コードがあればそれ、どちらも無ければ undefined", () => {
  assert.equal(exitCodeForExited(3, null), 3);
  assert.equal(exitCodeForExited(0, null), 0);
  assert.equal(exitCodeForExited(null, "SIGTERM"), 143);
  assert.equal(exitCodeForExited(null, "SIGKILL"), 137);
  assert.equal(exitCodeForExited(null, null), undefined);
});
