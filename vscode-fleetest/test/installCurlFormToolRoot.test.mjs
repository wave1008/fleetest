// install.sh の TOOL_ROOT 解決(ステップ0.5)が curl 形(`curl … | bash -s --`)でも
// preflight.sh/update.sh/toolRootResolve.ts と同じ規則(既定の隣より Package.swift の
// .package(path:) 宣言を優先する)に従うことの回帰テスト。
//
// 実害: install.sh は SELF_ROOT(BASH_SOURCE[0] がファイルであること = on-disk 実行)が
// 取れないとき、Package.swift の宣言を見ずにいきなり既定の隣(../fleetest)へ倒していた。
// curl 形(BASH_SOURCE[0] が空になる)では常にこの経路を通るため、`--tool-root <custom>` で
// 導入済みの受け手が引数無しで curl 形を再実行すると、既存のクローンを無視して
// 別の場所へ新しく clone しようとしていた。
//
// 本体を丸ごとは実行しない(clone/swift build を伴い重い上にネットワークが要る)。
// TOOL_ROOT 解決ブロックだけを文字列で切り出し、`bash -s --`(標準入力からの実行 = BASH_SOURCE[0]
// が空になり curl 形を再現する)/ 実ファイル実行(on-disk 形)の両方で走らせて解決結果を見る
// (installDivergedClone.test.mjs と同じ「実装の写しを置かない」方針)。

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

const ROOT = path.join(process.cwd(), "..");
const INSTALL_SH = path.join(ROOT, "Scripts/install.sh");

/** TOOL_ROOT_ARG/SELF_ROOT/DECLARED_ROOT の判定〜TOOL_ROOT_RAW の確定までを切り出す。 */
function toolRootBlock() {
  const source = readFileSync(INSTALL_SH, "utf8");
  const start = source.indexOf("# ---- 0.5 TOOL_ROOT(");
  assert.ok(start > 0, "Scripts/install.sh から `# ---- 0.5 TOOL_ROOT(` の見出しが見つからない。ブロックの見出しを変えたらこのテストの切り出しも直す(解決規則は install.sh / preflight.sh / update.sh / update-check.sh / toolRootResolve.ts で同じ。.claude/rules/installer-agents.md)");
  const end = source.indexOf('\nif [ -d "$TOOL_ROOT_RAW/.git"', start);
  assert.ok(end > start, "Scripts/install.sh の TOOL_ROOT 解決ブロックの終端(`if [ -d \"$TOOL_ROOT_RAW/.git\"`)が見つからない。切り出しの終端を直す");
  return source.slice(start, end);
}

/** dir を(判定に使う)最小のクローンにする: Package.swift + Sources/FTScenarioRunner/。 */
function makeCloneMarker(dir) {
  mkdirSync(path.join(dir, "Sources", "FTScenarioRunner"), { recursive: true });
  writeFileSync(path.join(dir, "Package.swift"), "// stub clone\n");
}

/** curl 形(標準入力からの bash -s --。BASH_SOURCE[0] は空)でブロックを実行し、
 * 解決された TOOL_ROOT_RAW を返す。 */
function resolveCurlForm({ workDir, toolRootArg = "" }) {
  const script = [
    `TOOL_ROOT_ARG=${JSON.stringify(toolRootArg)}`,
    `WORK_DIR=${JSON.stringify(workDir)}`,
    toolRootBlock(),
    'printf \'%s\' "$TOOL_ROOT_RAW"',
  ].join("\n");
  const res = spawnSync("bash", ["-s", "--"], { input: script, encoding: "utf8" });
  assert.equal(res.status, 0, `curl 形で Scripts/install.sh の TOOL_ROOT 解決ブロック(ステップ0.5)が失敗した(status=${res.status}): ${res.stderr}`);
  return res.stdout;
}

/** on-disk 形(実ファイルを bash <file> で実行。BASH_SOURCE[0] はそのファイル)で実行する。
 * selfCloneDir/Scripts/install.sh へブロックを書き出して実行する(SELF_ROOT の判定が
 * `dirname/..` を見るため、実際に Scripts/ の下に置く必要がある)。 */
function resolveOnDiskForm({ selfCloneDir, workDir, toolRootArg = "", isGitClone = true }) {
  makeCloneMarker(selfCloneDir);
  // 本物のクローンは .git を持つ。プラグインのキャッシュ(リポジトリ全体の写し)は持たない
  if (isGitClone) mkdirSync(path.join(selfCloneDir, ".git"), { recursive: true });
  const scriptsDir = path.join(selfCloneDir, "Scripts");
  mkdirSync(scriptsDir, { recursive: true });
  const scriptPath = path.join(scriptsDir, "install.sh");
  const script = [
    "#!/bin/bash",
    `TOOL_ROOT_ARG=${JSON.stringify(toolRootArg)}`,
    `WORK_DIR=${JSON.stringify(workDir)}`,
    toolRootBlock(),
    'printf \'%s\' "$TOOL_ROOT_RAW"',
  ].join("\n");
  writeFileSync(scriptPath, script);
  const res = spawnSync("bash", [scriptPath], { encoding: "utf8" });
  assert.equal(res.status, 0, `on-disk 形で Scripts/install.sh の TOOL_ROOT 解決ブロック(ステップ0.5)が失敗した(status=${res.status}): ${res.stderr}`);
  return res.stdout;
}

let base;
function freshBase() {
  base = mkdtempSync(path.join(tmpdir(), "ft-install-toolroot-"));
  return base;
}

test("curl 形: WORK_DIR/Package.swift が宣言する既存 TOOL_ROOT を既定の隣より優先する", (t) => {
  const dir = freshBase();
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const workDir = path.join(dir, "receiver");
  const customToolRoot = path.join(dir, "custom-tool-root");
  mkdirSync(workDir, { recursive: true });
  makeCloneMarker(customToolRoot);
  // 相対パス宣言(実際の install.sh が書く形と同じ)。既定の隣は作らない。
  writeFileSync(path.join(workDir, "Package.swift"), '.package(path: "../custom-tool-root")\n');

  const resolved = resolveCurlForm({ workDir });
  // install.sh は宣言をそのまま WORK_DIR に連結するだけで正規化しない(abspath は後段の役目)。
  assert.equal(resolved, `${workDir}/../custom-tool-root`,
    "curl 形(BASH_SOURCE が空)で WORK_DIR/Package.swift の .package(path:) 宣言が既定の隣(../fleetest)より優先されていない。宣言を見ずに既定へ倒すと導入済みの受け手が別の場所へ clone し直す。Scripts/install.sh のステップ0.5 を preflight.sh / update.sh / toolRootResolve.ts と同じ規則に揃える");
});

test("curl 形: --tool-root 明示は Package.swift の宣言より優先される", (t) => {
  const dir = freshBase();
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const workDir = path.join(dir, "receiver");
  const declaredToolRoot = path.join(dir, "declared-tool-root");
  const explicitToolRoot = path.join(dir, "explicit-tool-root");
  mkdirSync(workDir, { recursive: true });
  makeCloneMarker(declaredToolRoot);
  writeFileSync(path.join(workDir, "Package.swift"), '.package(path: "../declared-tool-root")\n');

  const resolved = resolveCurlForm({ workDir, toolRootArg: explicitToolRoot });
  assert.equal(resolved, explicitToolRoot,
    "--tool-root の明示が Package.swift の宣言より優先されていない(Scripts/install.sh ステップ0.5)");
});

test("curl 形: 宣言も既存クローンも無ければ既定の隣へ倒す(フォールバックは維持)", (t) => {
  const dir = freshBase();
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const workDir = path.join(dir, "receiver");
  mkdirSync(workDir, { recursive: true }); // Package.swift 無し

  const resolved = resolveCurlForm({ workDir });
  assert.equal(resolved, `${workDir}/../fleetest`,
    "宣言も既存クローンも無いとき既定の隣(../fleetest)へ倒れていない(Scripts/install.sh ステップ0.5)");
});

test("on-disk 形: 自分自身(SELF_ROOT)が Package.swift の宣言より優先される", (t) => {
  const dir = freshBase();
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const workDir = path.join(dir, "receiver");
  const selfCloneDir = path.join(dir, "self-clone");
  const declaredToolRoot = path.join(dir, "declared-tool-root");
  mkdirSync(workDir, { recursive: true });
  makeCloneMarker(declaredToolRoot);
  writeFileSync(path.join(workDir, "Package.swift"), '.package(path: "../declared-tool-root")\n');

  const resolved = resolveOnDiskForm({ selfCloneDir, workDir });
  assert.equal(resolved, selfCloneDir,
    "on-disk 形で自分自身(SELF_ROOT)が Package.swift の宣言より優先されていない(Scripts/install.sh ステップ0.5)");
});

// スキルはプラグインのキャッシュにある Scripts/install.sh を実行する。キャッシュはリポジトリ全体を
// 持つが git ではなく、更新で捨てられる場所 —— そこを TOOL_ROOT にするとキャッシュの中でビルドし、
// .mcp.json がそこを指す。.git の無い置き場からの実行は SELF_ROOT にしない。
test("on-disk 形: .git の無い置き場(プラグインのキャッシュ)からの実行は SELF_ROOT にせず宣言へ倒す", (t) => {
  const dir = freshBase();
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const workDir = path.join(dir, "receiver");
  const pluginCacheDir = path.join(dir, "plugin-cache");
  const declaredToolRoot = path.join(dir, "declared-tool-root");
  mkdirSync(workDir, { recursive: true });
  makeCloneMarker(declaredToolRoot);
  writeFileSync(path.join(workDir, "Package.swift"), '.package(path: "../declared-tool-root")\n');

  const resolved = resolveOnDiskForm({ selfCloneDir: pluginCacheDir, workDir, isGitClone: false });
  assert.equal(resolved, `${workDir}/../declared-tool-root`,
    "SELF_ROOT の判定が .git を条件にしていない。git でない複製(プラグインのキャッシュ等)を TOOL_ROOT にするとキャッシュの中でビルドし .mcp.json がそこを指す。Scripts/install.sh の SELF_ROOT に .git の有無を条件へ戻す(.claude/rules/installer-agents.md)");
});

test("on-disk 形: .git の無い置き場から未導入の WORK_DIR へは既定の隣へ倒す", (t) => {
  const dir = freshBase();
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const workDir = path.join(dir, "receiver");
  mkdirSync(workDir, { recursive: true });

  const resolved = resolveOnDiskForm({ selfCloneDir: path.join(dir, "plugin-cache"), workDir, isGitClone: false });
  assert.equal(resolved, `${workDir}/../fleetest`,
    ".git の無い置き場から未導入の WORK_DIR へ実行したとき既定の隣へ倒れていない(Scripts/install.sh ステップ0.5)");
});

/** 物理化と包含拒否のブロックを切り出す(die はスタブ)。 */
function containmentBlock() {
  const source = readFileSync(INSTALL_SH, "utf8");
  const start = source.indexOf('  TOOL_ROOT="$(cd "$TOOL_ROOT" && pwd -P)"');
  assert.ok(start > 0, "Scripts/install.sh から TOOL_ROOT の物理化(pwd -P)の行が見つからない。書き方を変えたらこのテストの切り出しも直す");
  const end = source.indexOf("  # ---- /包含拒否 ----", start);
  assert.ok(end > start, "Scripts/install.sh の包含拒否ブロックの終端マーカー `# ---- /包含拒否 ----` が見つからない。マーカーを残す");
  return source.slice(start, end);
}

function runContainment({ workDir, toolRoot }) {
  const script = [
    'die() { echo "DIE: $*"; exit 7; }',
    `TOOL_ROOT_RAW=${JSON.stringify(toolRoot)}`,
    `TOOL_ROOT=${JSON.stringify(toolRoot)}`,
    `WORK_DIR=${JSON.stringify(workDir)}`,
    containmentBlock(),
    'printf \'%s\\n%s\' "$WORK_DIR" "$TOOL_ROOT"',
  ].join("\n");
  return spawnSync("bash", ["-s", "--"], { input: script, encoding: "utf8" });
}

test("WORK_DIR = クローンのサブフォルダ → die する(未追跡資産を破棄させない)", (t) => {
  const dir = freshBase();
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const clone = path.join(dir, "fleetest");
  makeCloneMarker(clone);
  const sub = path.join(clone, "TestProjects");
  mkdirSync(sub, { recursive: true });
  const res = runContainment({ workDir: sub, toolRoot: clone });
  assert.equal(res.status, 7, `WORK_DIR がクローンのサブフォルダなのに die しなかった: ${res.stdout}${res.stderr}。受け手の未追跡の資産をクローンの更新で破棄させないため、Scripts/install.sh の包含拒否を戻す`);
  assert.match(res.stdout, /DIE: clone WORK_DIR .*inside the fleetest clone/);
});

test("WORK_DIR = クローンへのシンボリックリンク経由のサブフォルダでも die する", (t) => {
  const dir = freshBase();
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const clone = path.join(dir, "fleetest");
  makeCloneMarker(clone);
  mkdirSync(path.join(clone, "sub"), { recursive: true });
  const link = path.join(dir, "alias");
  symlinkSync(clone, link);
  const res = runContainment({ workDir: path.join(link, "sub"), toolRoot: clone });
  assert.equal(res.status, 7, `シンボリックリンク経由のサブフォルダがすり抜けた: ${res.stdout}${res.stderr}。Scripts/install.sh の包含拒否は物理パス(pwd -P)で比べる`);
});

test("WORK_DIR = クローンの最上位 / 隣のフォルダ / 名前だけ前方一致する兄弟 は die しない", (t) => {
  const dir = freshBase();
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const clone = path.join(dir, "fleetest");
  makeCloneMarker(clone);
  const sibling = path.join(dir, "fleetest-work"); // 文字列の前方一致だけでは子孫でない
  mkdirSync(sibling, { recursive: true });
  const receiver = path.join(dir, "receiver");
  mkdirSync(receiver, { recursive: true });
  for (const workDir of [clone, sibling, receiver]) {
    const res = runContainment({ workDir, toolRoot: clone });
    assert.equal(res.status, 0, `${workDir} を誤って拒否した: ${res.stdout}${res.stderr}。包含拒否はクローンの子孫だけを対象にする(文字列の前方一致で比べない。Scripts/install.sh)`);
  }
});
