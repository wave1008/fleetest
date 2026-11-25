// エージェント規約位置の言語跨ぎ整合検証。
//
// 契約: 規約位置(スキルの置き場所・入口ファイル・呼び出し記法)の定義元は
// Sources/FTCore/AgentIntegration.swift ただ1つ。ただし **install.sh は
// Swift を呼べない**(clone 前・ビルド前に走る)ので、同じ文字列をシェルにも手で書いている。
// **片方だけ変えると、CLI が書いた場所とインストーラが見る場所が食い違い、しかも
// 「動いているように見える」**(どちらも正しく動作するが、別の場所を触る)。
// ここが両者のドリフトを落とす。
//
// **インストーラが用意するのは Claude Code の規約位置だけ**。他のエージェント(Codex 等)は
// MCP 登録と SKILL.md 直読みで使う(docs/user-docs/reference/tools/other_agents.md)ので、
// その設定ファイル・規約位置へ書く経路が復活していないことも見る。
//
// process.cwd() は npm test 実行時に vscode-fleetest ルート。

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, existsSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

const ROOT = path.join(process.cwd(), "..");
const SWIFT = readFileSync(path.join(ROOT, "Sources/FTCore/AgentIntegration.swift"), "utf8");
const INSTALL_SH = readFileSync(path.join(ROOT, "Scripts/install.sh"), "utf8");

test("Swift の AgentIntegration が Claude Code の規約位置を持つ", () => {
  for (const value of [".claude/skills", "CLAUDE.md", ".mcp.json"]) {
    assert.ok(SWIFT.includes(`"${value}"`), `Sources/FTCore/AgentIntegration.swift に "${value}" がありません(規約位置の定義元はここ1つ。変えるなら Scripts/install.sh の同じ文字列も揃える。.claude/rules/installer-agents.md)`);
  }
  // 呼び出し記法(入口ファイルの本文で使う)
  assert.match(SWIFT, /skillInvocationPrefix/, "Sources/FTCore/AgentIntegration.swift に skillInvocationPrefix の定義がありません(入口ファイルの本文の呼び出し記法の定義元)");
});

test("スキルディレクトリの定義が Swift とインストーラで一致する", () => {
  const canon = SWIFT.match(/canonicalSkillsDirectory\s*=\s*"([^"]+)"/);
  assert.ok(canon, "AgentIntegration.canonicalSkillsDirectory がありません");
  assert.equal(canon[1], ".claude/skills");
  const dest = SWIFT.match(/\bskillsDirectory\s*=\s*"([^"]+)"/);
  assert.ok(dest, "AgentIntegration.skillsDirectory がありません");
  // install.sh ステップ7.8: 写し元は正典・置き先は規約位置(どちらも手で持つ)
  assert.ok(
    INSTALL_SH.includes(`sk_src="$TOOL_ROOT/${canon[1]}"`),
    `Scripts/install.sh の sk_src が "$TOOL_ROOT/${canon[1]}" ではありません。AgentIntegration.canonicalSkillsDirectory とドリフトさせない(片方だけ変えない。ステップ7.8)`,
  );
  assert.ok(
    INSTALL_SH.includes(`sk_dest="$WORK_DIR/${dest[1]}"`),
    `Scripts/install.sh の sk_dest が "$WORK_DIR/${dest[1]}" ではありません。AgentIntegration.skillsDirectory とドリフトさせない(片方だけ変えない。ステップ7.8)`,
  );
});

// --- 他のエージェントの設定には触らない ----------------------------------------
// 受け手のグローバル設定(~/.codex/config.toml 等)は**セキュリティ境界**で、書式も
// エージェントごとに違う(TOML はテーブルの重複で全体が無効になる)。インストーラが
// 面倒を見るのは Claude Code の規約位置だけで、他は手順書で案内する。

test("インストーラ一式が他エージェントの規約位置・設定へ書かない", () => {
  const files = ["Scripts/install.sh", "Scripts/update.sh", "Scripts/preflight.sh"];
  // AGENTS.md は禁止しない —— Claude Code 自身が v2.1.277 から読む入口になった(install.sh ステップ7.6)
  const forbidden = [/\.codex\//, /\.agents\/skills/, /codex plugin/];
  for (const rel of files) {
    const src = readFileSync(path.join(ROOT, rel), "utf8")
      .split("\n")
      .filter((line) => !line.trimStart().startsWith("#"))  // 説明のコメントは対象外
      .join("\n");
    for (const re of forbidden) {
      assert.ok(!re.test(src), `${rel} に他エージェント向けの経路が残っています: ${re}。インストーラが用意するのは Claude Code の規約位置だけで、Codex 等は MCP 登録と SKILL.md 直読み(docs/user-docs/reference/tools/other_agents.md の手順書)で案内する。その書き込みを消す(.claude/rules/installer-agents.md)`);
    }
  }
});

// --- ランナー機には入口ファイルを置かない -------------------------------------
// 入口(AGENTS.md / CLAUDE.md)は**人が開く機械**のためのもので、ランナー機には要らない。
// 抑止フラグを変えると Swift の実引数と docs の記載がドリフトするので、両方を見る。

test("RemoteSetup.installArgs が入口ファイルの生成を抑止する", () => {
  const swift = readFileSync(path.join(ROOT, "Sources/FTRemote/RemoteSetup.swift"), "utf8");
  assert.ok(swift.includes('"--skip-entry-point"'),
    "Sources/FTRemote/RemoteSetup.swift の installArgs に --skip-entry-point がありません。ランナー機には入口ファイル(AGENTS.md / CLAUDE.md)を置かないので、抑止フラグを戻す(docs/remote-runner/14-16.md の引数も揃える)");
});

test("ランナーの install 引数が docs と一致する(片方だけ変えない)", () => {
  const swift = readFileSync(path.join(ROOT, "Sources/FTRemote/RemoteSetup.swift"), "utf8");
  const body = swift.slice(swift.indexOf("func installArgs"));
  const flags = [...body.slice(0, body.indexOf("\n    }")).matchAll(/"(--[a-z-]+)"/g)]
    .map((m) => m[1])
    .filter((f) => f.startsWith("--skip") || f === "--no-next-steps");
  assert.ok(flags.length >= 3, `RemoteSetup.swift の installArgs から --skip* / --no-next-steps を抽出できません(関数の形が変わった。このテストの抽出を直す): ${flags}`);
  for (const doc of ["docs/remote-runner/14-16.md", "docs/remote-runner-setup.md"]) {
    const source = readFileSync(path.join(ROOT, doc), "utf8");
    const missing = flags.filter((f) => !source.includes(f));
    // --no-next-steps は setup 手順書には出ないので、そちらだけ緩める
    const required = doc.endsWith("14-16.md") ? missing : missing.filter((f) => f !== "--no-next-steps");
    assert.deepEqual(required, [],
      `${doc} が RemoteSetup.installArgs の抑止フラグを載せていません: ${required.join(", ")}。Sources/FTRemote/RemoteSetup.swift の実引数と docs は片方だけ変えない(docs 側へ足す)`);
  }
});

test("入口ファイルはクローンの中には書かない(未追跡でも)", () => {
  // 追跡の有無で判定すると、**まだ存在しない入口ファイル**が素通りする。
  // `git status --porcelain` は未追跡も dirty と数えるので、次の更新が pull ガードで止まる。
  // install.sh から write_entry_point を抜き出して実際に走らせる(実装の写しを置かない)。
  const begin = INSTALL_SH.indexOf("write_entry_point() {");
  assert.ok(begin > 0, "Scripts/install.sh に write_entry_point がありません(このテストは関数を抜き出して実際に走らせる。名前を変えたらここも直す)");
  const end = INSTALL_SH.indexOf("\n}\n", begin);
  const fn = INSTALL_SH.slice(begin, end + 3);

  const dir = mkdtempSync(path.join(tmpdir(), "ft-entry-guard-"));
  try {
    const clone = path.join(dir, "clone");
    const outside = path.join(dir, "work");
    mkdirSync(clone); mkdirSync(outside);
    execFileSync("git", ["init", "-q", clone]);
    const script = path.join(dir, "run.sh");
    // record は結果を1行で出すだけのスタブに差し替える
    writeFileSync(script, [
      "set -eu",
      'record() { echo "$1|$2"; }',
      fn,
      'WORK_DIR="$1"; TOOL_ROOT="$2"',
      // install.sh と同じく本文は AGENTS.md、CLAUDE.md は読み込みだけ
      'write_entry_point "$WORK_DIR/AGENTS.md" body',
      'write_entry_point "$WORK_DIR/CLAUDE.md" import',
    ].join("\n"));

    const inClone = execFileSync("bash", [script, clone, clone], { encoding: "utf8" });
    assert.match(inClone, /AGENTS\.md\|skip/, `write_entry_point がクローンの中の AGENTS.md を skip しない: ${inClone}。入口ファイルはクローンの中に書かない(未追跡でも pull ガードが止まる。install.sh の write_entry_point にクローン内の判定を戻す)`);
    assert.match(inClone, /CLAUDE\.md\|skip/, `クローンの中に書こうとしています: ${inClone}`);
    assert.ok(!existsSync(path.join(clone, "AGENTS.md")), "クローンに AGENTS.md が作られました");
    assert.ok(!existsSync(path.join(clone, "CLAUDE.md")), "クローンに CLAUDE.md が作られました");

    const outsideClone = execFileSync("bash", [script, outside, clone], { encoding: "utf8" });
    assert.match(outsideClone, /AGENTS\.md\|ok/, `クローンの外なのに書いていません: ${outsideClone}`);
    assert.match(outsideClone, /CLAUDE\.md\|ok/, `クローンの外なのに書いていません: ${outsideClone}`);
    assert.ok(existsSync(path.join(outside, "AGENTS.md")), "クローン外の AGENTS.md が作られていません");
    assert.ok(readFileSync(path.join(outside, "CLAUDE.md"), "utf8").includes("@AGENTS.md"),
      "クローン外の CLAUDE.md が AGENTS.md を読み込んでいません");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("install.sh のコピー対象は正典から導出し、fleetest-setup だけ除く", () => {
  // 手で持つと、スキルを増やす/改名するたびに直し忘れてコピーの受け手だけ取り残される。
  // fleetest-setup を除くのは、受け手のそれが `fleetest init` の生成物(別内容)だから
  assert.match(INSTALL_SH, /for sk_path in "\$sk_src"\/\*\/; do/,
    "Scripts/install.sh のステップ7.8 が正典 .claude/skills/ の走査(for sk_path in \"$sk_src\"/*/)からコピー対象を導出していません。手書きの一覧にするとスキルの増減で直し忘れる(.claude/rules/installer-agents.md)");
  assert.match(INSTALL_SH, /"\$sk_name" = "fleetest-setup"/,
    "Scripts/install.sh のステップ7.8 が fleetest-setup を除外していません。受け手のそれは `fleetest init` の生成物(別内容)なので上書きしない");
  // update.sh はコピーを自前で持たず、install.sh を再実行して更新する
  const updateSh = readFileSync(path.join(ROOT, "Scripts/update.sh"), "utf8");
  assert.ok(!/cp .*SKILL\.md/.test(updateSh), "Scripts/update.sh が SKILL.md を直接コピーしています。スキルのコピーを置く・更新するのは install.sh のステップ7.8 だけ(update.sh は install.sh を再実行する。.claude/rules/installer-agents.md)");
});

test("FLEETEST_REF がスクリプトの取得元とクローンの ref を揃える", () => {
  // 揃えないと「ブランチのスクリプトが main を clone し、main のバイナリに新しい引数を渡す」
  // 組み合わせが生まれ、Unknown option で落ちる(未マージのブランチ検証で実際に踏んだ)。
  // 受け手には影響しない(タグは main の祖先なので install.sh@main は常に新しい)が、
  // **直したはずの挙動を確認できない**という一番たちの悪い壊れ方をする
  assert.match(INSTALL_SH, /REF="\$\{FLEETEST_REF:-\}"/, "Scripts/install.sh が FLEETEST_REF を読んでいません(保守者のブランチ検証口。docs/releasing.md)");
  assert.match(INSTALL_SH, /git clone \$\{REF:\+--branch "\$REF"\}/,
    "Scripts/install.sh の新規 clone が FLEETEST_REF を --branch で指定していません。指定しないとブランチのスクリプトが main を clone して新しい引数で落ちる");
  assert.match(INSTALL_SH, /fetch --force --tags origin "\$REF"/,
    "Scripts/install.sh が既存クローンを FLEETEST_REF へ揃える fetch をしていません(fetch --force --tags origin \"$REF\")");
  // スキル側はクローンの Scripts/(手順書と同じ版)をローカルで実行する =
  // 手順書とスクリプトの版は構造的に揃う
  const setup = readFileSync(path.join(ROOT, ".claude/skills/fleetest-setup/SKILL.md"), "utf8");
  assert.match(setup, /bash <SCRIPTS>\/install\.sh/,
    ".claude/skills/fleetest-setup/SKILL.md が `bash <SCRIPTS>/install.sh` で手順書と同じ版の install.sh を実行していません。`curl … | bash` に戻さない(.claude/rules/installer-agents.md)");
});

test("スキルは curl | bash でスクリプトを実行しない", () => {
  // ネットワークから取ったスクリプトのパイプ実行はエージェントの安全確認に止められ、
  // 導入・更新の最初の一歩で進めなくなる。ローカルの Scripts/ を bash で実行する
  for (const name of ["fleetest-setup", "fleetest-update", "fleetest-mcp"]) {
    const skill = readFileSync(path.join(ROOT, ".claude/skills", name, "SKILL.md"), "utf8");
    const piped = skill.split("\n").filter((l) => /curl\s+(-\S+\s+)*https?:\/\/\S+[^\n]*\|\s*(ba)?sh\b/.test(l));
    assert.deepEqual(piped, [], `.claude/skills/${name}/SKILL.md が curl | bash を書いています: ${piped.map((l) => l.trim().slice(0, 80)).join(" / ")}。ネットワークから取ったスクリプトのパイプ実行はエージェントの安全確認に止められる。ローカルのクローンの Scripts/ を bash <SCRIPTS>/install.sh の形で実行する(.claude/rules/installer-agents.md)`);
  }
});

test("FLEETEST_REF は「版固定(detached)」ガードより先に効く", () => {
  // 後ろに置くと、**一度タグへ固定したクローンが二度とブランチへ戻れない**(実測で踏んだ)。
  // FLEETEST_REF は「ここへ動かせ」という明示指示なので、現在の状態に関わらず従う
  const refBranch = INSTALL_SH.indexOf('elif [ -n "$REF" ]; then');
  const pinnedGuard = INSTALL_SH.indexOf("version pinned:");
  assert.ok(refBranch > 0, "Scripts/install.sh に FLEETEST_REF の分岐(elif [ -n \"$REF\" ])がありません");
  assert.ok(pinnedGuard > 0, "Scripts/install.sh に版固定ガード(version pinned:)がありません");
  assert.ok(refBranch < pinnedGuard,
    "Scripts/install.sh で FLEETEST_REF の分岐が版固定ガードより後ろにある。FLEETEST_REF は明示指示なので固定の状態に関わらず先に効かせる(後ろだとタグへ固定したクローンがブランチへ戻れない)");
});

test("ref へ揃えるとき、ブランチは追跡付き・タグは detached", () => {
  // 追跡を張らないと、次に FLEETEST_REF 無しで実行したとき `git pull` が
  // 「no tracking information」で失敗し、戻れないまま毎回 warn が出る
  assert.match(INSTALL_SH, /checkout -q -B "\$REF" --track "origin\/\$REF"/,
    "Scripts/install.sh のブランチの checkout に --track がありません(無いと次の git pull が no tracking information で失敗する)");
  assert.match(INSTALL_SH, /checkout -q --detach FETCH_HEAD/,
    "Scripts/install.sh がタグ・SHA を checkout --detach FETCH_HEAD で detached にしていません");
  assert.match(INSTALL_SH, /ls-remote --exit-code --heads origin "\$REF"/,
    "Scripts/install.sh にブランチかどうかの判定(ls-remote --exit-code --heads)がありません");
});

test("タグの取得は付け直されたタグも上書きする(--force)", () => {
  // 外すと、上流でタグを付け直した後(履歴の書き換え)に既存クローンの fetch が would clobber で exit 1 になり、
  // move_to_release が「オフライン」と同じ戻り値で受け手を古い版に黙って留める
  const release = INSTALL_SH.slice(INSTALL_SH.indexOf("move_to_release() {"), INSTALL_SH.indexOf("release_track_applies() {"));
  assert.match(release, /fetch -q --force --tags origin/, "Scripts/install.sh の move_to_release のタグ取得に --force がありません。外すとタグの付け直し後に would clobber で失敗し、受け手が古い版に黙って留まる");
  assert.match(INSTALL_SH, /fetch --force --tags origin "\$REF"/, "Scripts/install.sh の FLEETEST_REF 経路のタグ取得に --force がありません(付け直されたタグを上書きできず失敗する)");
});

test("ref へ揃える経路でも自己再 exec の材料を取る", () => {
  // 取らないと、揃えた先の新しい install.sh が**その回に1つも実行されない**
  // (CLAUDE.md の再 exec の項と同じ実害)
  const refBranch = INSTALL_SH.indexOf('elif [ -n "$REF" ]; then');
  const section = INSTALL_SH.slice(refBranch, INSTALL_SH.indexOf("version pinned:"));
  const captured = section.indexOf("HEAD_BEFORE_PULL=");
  const fetched = section.indexOf("fetch --force --tags origin");
  assert.ok(captured > 0, "Scripts/install.sh の FLEETEST_REF 経路が HEAD_BEFORE_PULL を取っていません。取らないと揃えた先の新しい install.sh がその回に実行されない(自己再 exec の材料)");
  assert.ok(captured < fetched, "Scripts/install.sh の FLEETEST_REF 経路で HEAD_BEFORE_PULL を fetch の後で取っている(常に同じ値になり再 exec が働かない)。fetch の前へ置く");
});
