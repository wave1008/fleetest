// md2html.mjs の単体テスト。実行: node --test Scripts/md2html/
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { applyTemplate, convert, githubSlug, loadConfig } from "./md2html.mjs";

test("githubSlug は GitHub のアンカー規則(小文字化・記号除去・空白は -)", () => {
  assert.equal(githubSlug("Starting and Stopping by Hand"), "starting-and-stopping-by-hand");
  assert.equal(githubSlug("3. fleetest のインストール"), "3-fleetest-のインストール");
  assert.equal(githubSlug("run の前後で処理を走らせる(任意)"), "run-の前後で処理を走らせる任意");
  assert.equal(githubSlug("snake_case & `code`"), "snake_case--code");
});

test("applyTemplate は変数を置き換え、disable/enable の間と本文は置き換えない", () => {
  const t = "<a href=\"${relative}x\">${h1}</a>\n<!-- disable-variable -->\n${h1}\n<!-- enable-variable -->\n${contentHtml}";
  const html = applyTemplate(t, { relative: "../", h1: "T" }, "<p>${relative}</p>");
  assert.equal(html, "<a href=\"../x\">T</a>\n${h1}\n<p>${relative}</p>");
});

function site(files, extra = {}) {
  const root = mkdtempSync(path.join(tmpdir(), "md2html-test-"));
  for (const [p, body] of Object.entries(files)) {
    mkdirSync(path.dirname(path.join(root, p)), { recursive: true });
    writeFileSync(path.join(root, p), body);
  }
  writeFileSync(path.join(root, "cfg.json"), JSON.stringify({
    inputDirectory: "in", outputDirectory: "out", templateDirectory: "tpl", siteRoot: "https://example.test/x",
    generateSitemap: "false", languages: [{ suffix: "_ja", lang: "ja" }], ...extra,
  }));
  return { root, config: loadConfig(path.join(root, "cfg.json")) };
}

const TEMPLATE = "<html lang=\"${lang}\"><title>${h1}</title>${gtag}<a id=home href=\"${relative}index${langSuffix}.html\"></a>\n${contentHtml}</html>";

test("見出しに id・.md#frag を .html へ・言語の変数・素材を写す", () => {
  const { root, config } = site({
    "tpl/_template.html": TEMPLATE,
    "tpl/_template_gtag": "<script>g</script>",
    "tpl/_assets/main.css": "x",
    "in/index.md": "# Top\n\n[a](sub/page_ja.md#見出し-2)\n",
    "in/sub/page_ja.md": "# ページ\n\n## 見出し 2\n\n## 見出し 2\n\n![i](../img/a.png)\n",
    "in/img/a.png": "png",
  }, { gtag: "true" });
  const r = convert(config, { log: () => {} });
  assert.deepEqual(r.errors, []);
  const index = readFileSync(path.join(root, "out/index.html"), "utf8");
  assert.ok(index.includes(`href="sub/page_ja.html#${encodeURI("見出し-2")}"`), index); // markdown-it がエンコードする
  assert.match(index, /<html lang="en"><title>Top<\/title><script>g<\/script><a id=home href="index\.html">/);
  const page = readFileSync(path.join(root, "out/sub/page_ja.html"), "utf8");
  assert.match(page, /<html lang="ja">.*href="\.\.\/index_ja\.html"/);
  assert.match(page, /<h2 id="見出し-2">.*<h2 id="見出し-2-1">/s);
  assert.equal(readFileSync(path.join(root, "out/img/a.png"), "utf8"), "png");
  assert.equal(readFileSync(path.join(root, "out/_assets/main.css"), "utf8"), "x");
});

test("切れたリンク・無い見出し・入力の外へのリンクを検査で落とす", () => {
  const { config } = site({
    "tpl/_template.html": TEMPLATE,
    "in/index.md": "# T\n\n[a](nope.md) [b](index.md#無い) [c](../outside.md) ![d](x.png)\n",
  });
  const r = convert(config, { log: () => {} });
  assert.equal(r.errors.length, 4, r.errors.join("\n"));
  assert.ok(r.errors.some((e) => e.includes("nope.html(ファイルが無い)")));
  assert.ok(r.errors.some((e) => e.includes("(見出しが無い)")));
  assert.ok(r.errors.some((e) => e.includes("入力フォルダの外")));
  assert.ok(r.errors.some((e) => e.includes("x.png(ファイルが無い)")));
});

test("md2html の出力でない中身がある outputDirectory は消さずに止める", () => {
  const { root, config } = site({ "tpl/_template.html": TEMPLATE, "in/index.md": "# T\n", "out/keep.txt": "mine" });
  assert.throws(() => convert(config, { log: () => {} }), /md2html の出力でない中身/);
  assert.equal(readFileSync(path.join(root, "out/keep.txt"), "utf8"), "mine");
  // 2回目以降(印がある)は作り直してよい
  const { config: c2 } = site({ "tpl/_template.html": TEMPLATE, "in/index.md": "# T\n" });
  convert(c2, { log: () => {} });
  convert(c2, { log: () => {} });
});
