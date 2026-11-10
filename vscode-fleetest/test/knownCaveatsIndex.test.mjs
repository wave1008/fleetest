// 注意事項の一覧(docs/user-docs/reference/writing/known_caveats*.md)が、利用者向けの文書にある注意事項を1件残らず指しているか。
// シナリオを書く AI は一覧だけを必ず読む(fleetest-scenario の SKILL.md・agent_guide)ので、一覧から漏れた注意事項は AI に届かない。
// 数えるもの: コマンドのページ等の「## 注意点」/「## Notes」の節の箇条書き1つ = 1件、「**現時点の制約**」/「**Current limitation**」の
// 1箇所 = 1件(直後が箇条書きならその項目ごとに1件)。一覧の項目は「- [要点](ページ#節)」で、同じ節を指す項目の本数 = その節の件数。
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const userDocs = path.join(repo, "docs/user-docs");
const indexRel = { ja: "reference/writing/known_caveats_ja.md", en: "reference/writing/known_caveats.md" };

/** GitHub の見出しのアンカー(小文字・文字/数字/結合文字/下線/空白/ハイフン以外を落とす・空白をハイフンに) */
export function slug(heading) {
  return heading.trim().toLowerCase().replace(/[^\p{L}\p{M}\p{N}\p{Pc} -]/gu, "").replace(/ /g, "-");
}

/** 1ページの注意事項を、属する節のアンカーの列で返す(1件 = 1要素)。コードブロックの中は見ない */
export function caveatAnchors(source, lang) {
  const notesHeading = lang === "ja" ? /^## 注意点\s*$/ : /^## Notes\s*$/;
  const marker = lang === "ja" ? "**現時点の制約**" : "**Current limitation**";
  const lines = source.replace(/```[\s\S]*?```/g, (block) => block.replace(/[^\n]/g, "")).split("\n");
  const anchors = [];
  let anchor = null;
  let inNotes = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const heading = line.match(/^#{2,6}\s+(.+?)\s*$/);
    if (heading) {
      anchor = slug(heading[1]);
      inNotes = notesHeading.test(line);
      continue;
    }
    if (inNotes) {
      if (/^- /.test(line)) anchors.push(anchor);
      continue;
    }
    const at = line.indexOf(marker);
    if (at < 0) continue;
    const rest = line.slice(at + marker.length).replace(/^\s*[:：]\s*/, "").trim();
    if (rest !== "") {
      anchors.push(anchor);
      continue;
    }
    // 見出し語だけの行: 直後の箇条書きの項目ごとに1件(継続行・空行・消したコードブロックは読み飛ばす。段落か見出しで終わる)
    let items = 0;
    for (let j = i + 1; j < lines.length; j++) {
      const next = lines[j];
      if (/^- /.test(next)) items++;
      else if (next.trim() === "" || /^\s+\S/.test(next)) continue;
      else break;
    }
    for (let k = 0; k < Math.max(items, 1); k++) anchors.push(anchor);
  }
  return anchors;
}

/** 一覧の項目(「- [..](相対パス#アンカー)」)を、user-docs からのパス#アンカーの列で返す */
export function indexTargets(source, indexDir) {
  const targets = [];
  for (const line of source.split("\n")) {
    if (!/^- /.test(line)) continue;
    const link = line.match(/\]\(([^)\s#]+\.md)#([^)\s]+)\)/);
    if (!link) continue;
    targets.push(`${path.posix.normalize(path.posix.join(indexDir, link[1]))}#${decodeURIComponent(link[2])}`);
  }
  return targets;
}

function walk(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) =>
    entry.isDirectory() ? walk(path.join(dir, entry.name)) : entry.name.endsWith(".md") ? [path.join(dir, entry.name)] : []);
}

function counts(keys) {
  const map = new Map();
  for (const key of keys) map.set(key, (map.get(key) ?? 0) + 1);
  return map;
}

for (const lang of ["ja", "en"]) {
  test(`注意事項の一覧(${lang})が全ページの注意事項を節ごとに同じ件数だけ指す`, () => {
    const expected = [];
    for (const file of walk(userDocs)) {
      const rel = path.relative(userDocs, file).split(path.sep).join("/");
      if (rel === indexRel[lang] || rel.endsWith("_ja.md") !== (lang === "ja")) continue;
      for (const anchor of caveatAnchors(fs.readFileSync(file, "utf8"), lang)) expected.push(`${rel}#${anchor}`);
    }
    const indexSource = fs.readFileSync(path.join(userDocs, indexRel[lang]), "utf8");
    const actual = indexTargets(indexSource, path.posix.dirname(indexRel[lang]));
    const want = counts(expected);
    const got = counts(actual);
    const problems = [];
    for (const [key, n] of want) if ((got.get(key) ?? 0) !== n) problems.push(`${key}: 元の文書 ${n} 件・一覧 ${got.get(key) ?? 0} 件`);
    for (const [key, n] of got) if (!want.has(key)) problems.push(`${key}: 一覧 ${n} 件・元の文書に無い節(リンク先の誤りか、注意事項が消えた)`);
    assert.deepEqual(problems, [], `注意事項を足した・消したら ${indexRel[lang]} も直す:\n${problems.join("\n")}`);
    assert.ok(expected.length > 100, `数えた注意事項が ${expected.length} 件しかない(走査が文書に届いていない)`);
  });
}

test("数え方: 注意点の節の箇条書き・見出し語つきの1行・見出し語の後の箇条書き・コードブロックの中は数えない", () => {
  const ja = [
    "# T", "## 関数", "- 関数の説明(数えない)", "## 注意点", "- 一つ目", "  続きの行", "- 二つ目", "```swift", "- コードの中", "```",
    "### Link", "- [index](x.md)", "## 部品 A(説明)", "**現時点の制約**: 一行の制約", "## 部品 B", "**現時点の制約**:", "",
    "- 項目1", "  続き", "", "  ```swift", "  tap()", "  ```", "- 項目2", "", "段落で終わる", "- 段落の後の箇条書き(数えない)",
  ].join("\n");
  assert.deepEqual(caveatAnchors(ja, "ja"), ["注意点", "注意点", "部品-a説明", "部品-b", "部品-b"]);
  assert.deepEqual(caveatAnchors("# T\n## Notes\n- a\n## Example\n- b\n", "en"), ["notes"]);
  assert.deepEqual(caveatAnchors("# T\n## 例\n- 例の箇条書き\n", "ja"), []);
});

test("一覧の項目: 箇条書きのリンクだけを user-docs からのパスに直す", () => {
  const source = "前置き [x](../a.md#b)\n- [要点](../commands/tap_ja.md#注意点) — 説明\n- [要点2](ui_ja.md#%E9%83%A8%E5%93%81)\n";
  assert.deepEqual(indexTargets(source, "reference/writing"),
    ["reference/commands/tap_ja.md#注意点", "reference/writing/ui_ja.md#部品"]);
});
