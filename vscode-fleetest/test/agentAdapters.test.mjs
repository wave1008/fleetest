// スキル配布の整合検証。
// 契約(DS-15): **runbook 本体は複製しない**。正典は .claude/skills/ の1箇所で、
// 受け手の作業フォルダへは install.sh(ステップ7.8)がコピーを置く。配布は「クローンを読ませる」1本
// (プラグイン・curl 取得は廃止済み。MN-2.3)。
// スキルの呼び出し名は SKILL.md frontmatter の name から決まるため、ディレクトリ名との一致も見る。
//
// process.cwd() は npm test 実行時に vscode-fleetest ルート(protocolVersion.test.mjs と同じ前提)。

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = path.join(process.cwd(), "..");

test("各スキルの frontmatter name がディレクトリ名と一致する", () => {
  const skillsDir = path.join(ROOT, ".claude", "skills");
  const dirs = readdirSync(skillsDir, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name);
  assert.ok(dirs.length >= 4, `.claude/skills/ のスキルが少なすぎます(読み取りの前提が崩れた): ${dirs.join(", ")}`);

  for (const dir of dirs) {
    const skillPath = path.join(skillsDir, dir, "SKILL.md");
    assert.ok(existsSync(skillPath), `.claude/skills/${dir}/SKILL.md がありません(スキルのディレクトリには SKILL.md が要る)`);
    const src = readFileSync(skillPath, "utf8");
    const name = src.match(/^---\n(?:.*\n)*?name:\s*(\S+)\s*\n/)?.[1];
    assert.equal(
      name,
      dir,
      `.claude/skills/${dir}/SKILL.md の frontmatter name が "${name}" でディレクトリ名 "${dir}" と不一致(呼び出し名は name から決まる。name かディレクトリ名のどちらかを揃える)`,
    );
  }
});

test("廃止したプラグイン配布・curl 取得が復活していない", () => {
  for (const rel of [".claude-plugin", "Scripts/install-skill.sh", "skills"]) {
    assert.ok(!existsSync(path.join(ROOT, rel)), `${rel} が復活しています。配布は「クローンを読ませる」1本で、スキルのコピーは install.sh のステップ7.8 だけが置く。プラグイン配布・curl 取得は廃止済みなので消す(MN-2.3・.claude/rules/installer-agents.md)`);
  }
});

// repo ルートの `.mcp.json` は中身が `$PWD/Scripts/mcp-server.sh` 依存で、クローンの外では必ず落ちる。
// 登録は構成を問わず install.sh が絶対パスで WORK_DIR へ書く。
test("repo ルートに .mcp.json を置かない(クローンの外で起動できない)", () => {
  assert.ok(
    !execFileSync("git", ["ls-files", ".mcp.json"], { cwd: ROOT, encoding: "utf8" }).trim(),
    "repo ルートの .mcp.json が git 管理されている。中身が $PWD/Scripts/mcp-server.sh 依存でクローンの外では起動しない。git rm して、登録は install.sh が WORK_DIR へ絶対パスで書く形に任せる(.claude/rules/installer-agents.md)",
  );
});

test("install.sh は構成を問わず .mcp.json を書く(clone 構成を同梱ファイルに頼らない)", () => {
  const sh = readFileSync(path.join(ROOT, "Scripts/install.sh"), "utf8");
  assert.ok(
    !/bundled \.mcp\.json/.test(sh),
    "Scripts/install.sh が clone 構成で .mcp.json の生成をスキップしている(`bundled .mcp.json` の分岐を戻さない)。構成を問わず WORK_DIR へ絶対パスで書く(.claude/rules/installer-agents.md)",
  );
});
