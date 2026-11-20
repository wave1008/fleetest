#!/usr/bin/env node
// md2html(Shirates の io.github.ldi-github:md2html 0.2.0)の Node 移植。Markdown のフォルダを静的サイトへ変換する。
//
// 使い方(元と同じ形): node md2html.mjs [<設定ファイル>] [key=value ...]
//   設定ファイルの既定は カレントの md2htmlConfig.json。key=value は設定の上書き(元の `gtag=true` もこの形)。
//
// 設定(JSON。相対パスは設定ファイルのあるフォルダから。key=value で上書きした相対パスはカレントから):
//   inputDirectory    Markdown のフォルダ(元と同じ)
//   outputDirectory   出力先(元と同じ)。前回この道具が書いた印(.md2html-output)があるか空なら作り直す。他の中身があれば断る
//   generateSitemap   "true" / "false"(元と同じ)。lastmod は git log
//   siteRoot          公開 URL(元と同じ。必須)
//   templateDirectory _template.html・_template_gtag・_assets を置くフォルダ(既定 = inputDirectory = 元と同じ)
//   gtag              "true" で _template_gtag を ${gtag} に入れる(元は引数 gtag=true だけ)
//   ref               git の ref。指定すると inputDirectory をその ref の中身から読む(作業ツリーの未コミット分を混ぜない)
//   outsideLinkBase   inputDirectory の外を指す相対リンクの書き換え先。`${ref}` と、リポジトリ直下からのパスを後ろに付ける
//                     (例 https://github.com/wave1008/fleetest/blob/${ref}/)。無ければ外へのリンクは切れたリンクとして断る
//   languages         [{ "suffix": "_ja", "lang": "ja" }]。ファイル名(拡張子の前)の接尾辞で ${lang}・${langSuffix} を決める
//   defaultLanguage   接尾辞に当たらないページの ${lang}(既定 "en")
//   typographer       "true" で引用符・記号を活字体へ(元の TypographicExtension 相当。GitHub の表示とずれるので既定 "false")
//   description       { "<lang>": "..." }。導入の段落が無いページの ${description}
//   checkLinks        "false" で切れたリンクの検査を止める(既定 "true" = 1件でもあれば非ゼロで終わる)
//
// テンプレート変数(元と同じ): ${contentHtml} ${relative} ${assets} ${h1} ${gtag}
//   追加: ${lang} ${langSuffix}(言語の接尾辞。英語は空)
//         ${siteRoot}(末尾 /)${pageUrl}(そのページの絶対 URL)${description}(導入の段落の平文か設定の description。OGP 用。属性値としてエスケープ済み)
//   行に `<!-- disable-variable -->` / `<!-- enable-variable -->` だけを書くと、その間の行は変数を置き換えない(元と同じ)
//
// 元との違い(どれも元では壊れていた所):
//   - 見出しに GitHub と同じ規則の id を付ける(元は付けず、`#見出し` へのリンクが全部切れた)
//   - `foo.md#frag` も .html へ(元は `.md` で終わる href だけ)
//   - 本文の中の `${relative}` 等は置き換えない(元は本文を差し込んでから置き換えたので、コード例の文字列が化けた)
//   - img の src だけでなく、リンクされた .md 以外のファイルも出力へ写す
//   - sitemap の lastmod は W3C の書式(元の `%ai` は空白入りで仕様外)
//   - WikiLink(`[[...]]`)は移植していない(fleetest の docs は使っていない)

import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const OUTPUT_MARK = ".md2html-output";

// このフォルダで npm ci した markdown-it。無ければ拡張の node_modules(vsce の依存)で手元の確認だけ回せる
function loadMarkdownIt() {
  for (const base of [HERE, path.resolve(HERE, "../../vscode-fleetest")]) {
    try { return createRequire(path.join(base, "package.json"))("markdown-it"); } catch { /* 次へ */ }
  }
  throw new Error("markdown-it が見つからない。Scripts/md2html で npm ci を実行する");
}

const PATH_KEYS = ["inputDirectory", "outputDirectory", "templateDirectory"];

export function loadConfig(configFile = "md2htmlConfig.json", args = [], cwd = process.cwd()) {
  const configPath = path.resolve(cwd, configFile);
  const raw = JSON.parse(readFileSync(configPath, "utf8"));
  const c = {};
  for (const [k, v] of Object.entries(raw)) c[k] = PATH_KEYS.includes(k) ? path.resolve(path.dirname(configPath), v) : v;
  for (const a of args) {
    const at = a.indexOf("=");
    if (at <= 0) throw new Error(`引数は key=value: ${a}`);
    const k = a.slice(0, at), v = a.slice(at + 1);
    c[k] = PATH_KEYS.includes(k) ? path.resolve(cwd, v) : v;
  }
  if (!c.siteRoot) throw new Error("siteRoot is required in md2htmlConfig.json.");
  if (!c.siteRoot.endsWith("/")) c.siteRoot += "/";
  c.inputDirectory ??= path.resolve(cwd, "doc/markdown");
  c.outputDirectory ??= path.resolve(cwd, "doc/out");
  c.templateDirectory ??= c.inputDirectory;
  c.generateSitemap = String(c.generateSitemap ?? "true") === "true";
  c.gtag = String(c.gtag ?? "false") === "true";
  c.description ??= {};
  c.typographer = String(c.typographer ?? "false") === "true";
  c.checkLinks = String(c.checkLinks ?? "true") === "true";
  c.languages ??= [];
  c.defaultLanguage ??= "en";
  c.ref ||= null;
  return c;
}

// github-slugger と同じ: 小文字化 → 文字・数字・結合記号・連結句読点・'-'・' ' 以外を除く → ' ' を '-' に
export function githubSlug(text) {
  return text.toLowerCase().replace(/[^\p{L}\p{N}\p{M}\p{Pc}\- ]/gu, "").replace(/ /g, "-");
}

const escapeText = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const escapeAttr = (s) => escapeText(s).replace(/"/g, "&quot;");
/** リンクプレビュー(og:description)の上限。X・Slack は約 200 字で切るので、それより先は送っても表示されない */
const DESCRIPTION_MAX_CHARS = 200;

/** 導入の段落(最初の h2 より前・最上位)の平文。リンクだけの段落(言語切替 `[in English](...)`)は飛ばす。無ければ "" */
export function pageDescription(tokens) {
  for (let i = 0; i < tokens.length; i++) {
    if (tokens[i].type === "heading_open" && tokens[i].tag !== "h1") return "";
    if (tokens[i].type !== "paragraph_open" || tokens[i].level !== 0 || tokens[i + 1]?.type !== "inline") continue;
    const kids = tokens[i + 1].children ?? [];
    let text = "", inLink = 0, outside = "";
    for (const k of kids) {
      if (k.type === "link_open") inLink++;
      else if (k.type === "link_close") inLink--;
      const t = k.type === "text" || k.type === "code_inline" ? k.content
        : k.type === "softbreak" || k.type === "hardbreak" ? "\n" : "";
      text += t;
      if (!inLink) outside += t;
    }
    if (!outside.trim()) continue;
    // 折り返しは日本語どうしの間なら詰める(空白を入れると「して、 出力」になる)・それ以外は空白
    text = text.replace(/([^\x00-\x7F])\n(?=[^\x00-\x7F])/g, "$1").replace(/\s+/g, " ").trim();
    return text.length > DESCRIPTION_MAX_CHARS ? text.slice(0, DESCRIPTION_MAX_CHARS - 1) + "…" : text;
  }
  return "";
}
const isExternal = (url) => /^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(url) || url.startsWith("//");

/** 元の行単位の置き換え。disable/enable の行そのものは出力しない */
export function applyTemplate(template, vars, contentHtml) {
  let replace = true;
  const out = [];
  for (const line of template.split("\n")) {
    const t = line.trim();
    if (t === "<!-- disable-variable -->") { replace = false; continue; }
    if (t === "<!-- enable-variable -->") { replace = true; continue; }
    let l = line;
    if (replace) for (const [k, v] of Object.entries(vars)) l = l.replaceAll("${" + k + "}", v);
    out.push(l);
  }
  // 本文は最後に差し込む(本文中の `${relative}` 等の文字列を置き換えない)
  return out.join("\n").replace("${contentHtml}", () => contentHtml);
}

function listMarkdown(dir, base = dir) {
  const out = [];
  for (const e of readdirSync(dir)) {
    const full = path.join(dir, e);
    if (statSync(full).isDirectory()) out.push(...listMarkdown(full, base));
    else if (e.endsWith(".md")) out.push(path.relative(base, full).split(path.sep).join("/"));
  }
  return out.sort();
}

function gitTop(dir) {
  return execFileSync("git", ["-C", dir, "rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim();
}

/** 入力の用意。ref 指定ならその ref の inputDirectory を git archive で取り出す */
function prepareInput(c) {
  const repo = gitTopOrNull(existsSync(c.inputDirectory) ? c.inputDirectory : path.dirname(c.templateDirectory));
  const repoPath = repo ? path.relative(repo, c.inputDirectory).split(path.sep).join("/") : null;
  if (!c.ref) return { dir: c.inputDirectory, repo, repoPath, cleanup: () => {} };
  if (!repo) throw new Error("ref を使うには inputDirectory が git リポジトリの中にある必要がある");
  const tmp = mkdtempSync(path.join(tmpdir(), "md2html-"));
  const tar = execFileSync("git", ["-C", repo, "archive", "--format=tar", `${c.ref}:${repoPath}`], { maxBuffer: 1 << 30 });
  execFileSync("tar", ["-x", "-C", tmp], { input: tar });
  return { dir: tmp, repo, repoPath, cleanup: () => rmSync(tmp, { recursive: true, force: true }) };
}

function gitTopOrNull(dir) {
  try { return gitTop(dir); } catch { return null; }
}

function prepareOutput(out) {
  if (existsSync(out)) {
    const entries = readdirSync(out);
    if (entries.length && !entries.includes(OUTPUT_MARK)) {
      throw new Error(`outputDirectory に md2html の出力でない中身がある(消さずに止める): ${out}`);
    }
    rmSync(out, { recursive: true, force: true });
  }
  mkdirSync(out, { recursive: true });
  writeFileSync(path.join(out, OUTPUT_MARK), "");
}

export function convert(c, { log = console.log } = {}) {
  const MarkdownIt = loadMarkdownIt();
  const md = new MarkdownIt({ html: true, linkify: true, typographer: c.typographer });
  md.linkify.set({ fuzzyEmail: false }); // 元の AutolinkExtension.IGNORE_LINKS(メールアドレスをリンクにしない)
  const input = prepareInput(c);
  try {
    log("/// Converting md to html");
    prepareOutput(c.outputDirectory);
    const templatePath = path.join(c.templateDirectory, "_template.html");
    const template = readFileSync(templatePath, "utf8");
    const gtagPath = path.join(c.templateDirectory, "_template_gtag");
    const gtag = c.gtag && existsSync(gtagPath) ? readFileSync(gtagPath, "utf8") : "";

    const pages = listMarkdown(input.dir);
    const ids = new Map();
    const links = [];
    const files = new Set();
    const errors = [];

    for (const page of pages) {
      log(page);
      const pageHtml = page.replace(/\.md$/, ".html");
      const pageDir = path.posix.dirname(page);
      const rewrite = (url) => {
        if (!url || url.startsWith("/") || isExternal(url)) return url;
        if (url.startsWith("#")) { links.push({ page: pageHtml, url }); return url; }
        const hashAt = url.indexOf("#");
        let p = hashAt < 0 ? url : url.slice(0, hashAt);
        const frag = hashAt < 0 ? "" : url.slice(hashAt);
        const target = path.posix.normalize(path.posix.join(pageDir, decodeURI(p)));
        if (target === ".." || target.startsWith("../")) {
          if (c.outsideLinkBase && input.repoPath !== null) {
            const repoTarget = path.posix.normalize(path.posix.join(input.repoPath, target));
            return c.outsideLinkBase.replaceAll("${ref}", c.ref ?? "main") + repoTarget + frag;
          }
          errors.push(`${pageHtml}: ${url}(入力フォルダの外。outsideLinkBase が無い)`);
          return url;
        }
        if (p.endsWith(".md")) p = p.slice(0, -3) + ".html";
        else if (p) files.add(target);
        links.push({ page: pageHtml, url: p + frag });
        return p + frag;
      };

      const env = {};
      const tokens = md.parse(readFileSync(path.join(input.dir, page), "utf8"), env);
      const seen = new Map();
      const pageIds = new Set();
      let h1 = "";
      for (let i = 0; i < tokens.length; i++) {
        const t = tokens[i];
        if (t.type === "heading_open") {
          const text = tokens[i + 1].children
            .filter((x) => x.type === "text" || x.type === "code_inline").map((x) => x.content).join("").trim();
          if (t.tag === "h1" && !h1) h1 = text;
          const base = githubSlug(text);
          const n = seen.get(base) ?? 0;
          seen.set(base, n + 1);
          const id = n === 0 ? base : `${base}-${n}`;
          t.attrSet("id", id);
          pageIds.add(id);
        }
        for (const x of [t, ...(t.children ?? [])]) {
          if (x.type === "link_open") x.attrSet("href", rewrite(x.attrGet("href")));
          else if (x.type === "image") x.attrSet("src", rewrite(x.attrGet("src")));
          else if (x.type === "html_block" || x.type === "html_inline") {
            x.content = x.content
              .replace(/(<img\s[^>]*?src=")([^"]+)(")/g, (_, a, u, b) => a + rewrite(u) + b)
              .replace(/(<a\s[^>]*?href=")([^"]+)(")/g, (_, a, u, b) => a + rewrite(u) + b);
          }
        }
      }
      ids.set(pageHtml, pageIds);

      const stem = page.replace(/\.md$/, "");
      const language = c.languages.find((l) => stem.endsWith(l.suffix));
      const relative = "../".repeat(page.split("/").length - 1);
      const html = applyTemplate(template, {
        relative,
        assets: `${relative}_assets`,
        h1: escapeText(h1),
        gtag,
        siteRoot: escapeAttr(c.siteRoot),
        pageUrl: escapeAttr(c.siteRoot + pageHtml),
        description: escapeAttr(pageDescription(tokens) || c.description[language?.lang ?? c.defaultLanguage] || ""),
        lang: language?.lang ?? c.defaultLanguage,
        langSuffix: language?.suffix ?? "",
      }, md.renderer.render(tokens, md.options, env));
      mkdirSync(path.join(c.outputDirectory, path.dirname(pageHtml)), { recursive: true });
      writeFileSync(path.join(c.outputDirectory, pageHtml), html);
    }

    for (const f of files) {
      const from = path.join(input.dir, f);
      if (!existsSync(from) || statSync(from).isDirectory()) continue; // 検査が「ファイルが無い」で拾う
      mkdirSync(path.join(c.outputDirectory, path.dirname(f)), { recursive: true });
      copyFileSync(from, path.join(c.outputDirectory, f));
    }
    const assetsDir = path.join(c.templateDirectory, "_assets");
    if (existsSync(assetsDir)) {
      execFileSync("cp", ["-R", assetsDir + "/", path.join(c.outputDirectory, "_assets")]);
    }

    if (c.checkLinks) {
      for (const { page, url } of links) {
        const hashAt = url.indexOf("#");
        const p = hashAt < 0 ? url : url.slice(0, hashAt);
        const frag = hashAt < 0 ? "" : decodeURIComponent(url.slice(hashAt + 1));
        const target = p ? path.posix.normalize(path.posix.join(path.posix.dirname(page), decodeURI(p))) : page;
        const full = path.join(c.outputDirectory, target);
        if (!existsSync(full) || statSync(full).isDirectory()) errors.push(`${page}: ${url}(ファイルが無い)`);
        else if (frag && ids.has(target) && !ids.get(target).has(frag)) errors.push(`${page}: ${url}(見出しが無い)`);
      }
    }

    if (c.generateSitemap && errors.length === 0) {
      log("/// Generating sitemap.xml");
      const urls = pages.map((page) => {
        let lastmod = "";
        if (input.repo) {
          lastmod = execFileSync("git", ["-C", input.repo, "log", "-1", "--format=%cI", c.ref ?? "HEAD", "--",
            `${input.repoPath}/${page}`], { encoding: "utf8" }).trim();
        }
        return `  <url>\n    <loc>${escapeText(c.siteRoot + page.replace(/\.md$/, ".html"))}</loc>\n` +
          (lastmod ? `    <lastmod>${lastmod}</lastmod>\n` : "") + "  </url>";
      });
      writeFileSync(path.join(c.outputDirectory, "sitemap.xml"),
        `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls.join("\n")}\n</urlset>\n`);
    }
    return { pages, files: [...files], links: links.length, errors };
  } finally {
    input.cleanup();
  }
}

function main() {
  const argv = process.argv.slice(2);
  const configFile = argv[0] && !argv[0].includes("=") ? argv.shift() : undefined;
  const c = loadConfig(configFile, argv);
  const r = convert(c, { log: () => {} });
  if (r.errors.length) {
    console.error(r.errors.join("\n"));
    console.error(`切れたリンク ${r.errors.length} 件(公開しない)`);
    process.exit(1);
  }
  console.log(`${r.pages.length} ページ・ファイル ${r.files.length} 件・リンク ${r.links} 本を検査して OK → ${c.outputDirectory}`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
