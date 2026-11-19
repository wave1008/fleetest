# 利用者向けドキュメントのサイト(GitHub Pages)

docs/user-docs を https://wave1008.github.io/fleetest/ へ公開するときの、サイトの見た目と設定。
変換は `Scripts/md2html/md2html.mjs`(Shirates の md2html の Node 移植。設定項目の一覧はファイル先頭のコメント)。
公開は `.github/workflows/user-docs-pages.yml`(GitHub Release の公開時と手動実行。中身は最新リリースのタグの docs/user-docs)。

| ファイル | 中身 |
|---|---|
| `md2htmlConfig.json` | 変換の設定(入力・出力・公開 URL・言語の接尾辞・外へのリンクの書き換え先・gtag の有無) |
| `_template.html` | 全ページ共通の HTML。変数 `${contentHtml}` `${relative}` `${assets}` `${h1}` `${gtag}` `${lang}` `${langSuffix}` `${siteRoot}` `${pageUrl}` `${description}`。リンクプレビュー(OGP)のタグもここ |
| `_assets/` | 出力の `_assets/` へそのまま写る(CSS・画像・JS) |
| `_assets/og.jpg` | リンクプレビューの画像(1200×630 = 各サービスが切らずに出す 1.91:1・JPEG 品質 85 で約 120KB・日英共通。`og:image` は絶対 URL でないと読まれないので `${siteRoot}` から組む)。差し替えたら `_template.html` の `og:image:width` / `og:image:height` も合わせる |
| `_template_gtag` | Google Analytics のタグ。公開のワークフローだけが `gtag=true` を渡して `${gtag}` に入れる(Shirates と同じ。手元の確認では入らない = 計測されない) |

## 手元で確かめる

```bash
npm ci --prefix Scripts/md2html        # 初回だけ(無くても vscode-fleetest/node_modules の markdown-it で動く)
node Scripts/md2html/md2html.mjs Scripts/user-docs-site/md2htmlConfig.json
open .build/user-docs-site/index_ja.html
```

- 作業ツリーの docs/user-docs を変換する。公開と同じタグの中身で見るなら `ref=<タグ>` を足す
- 切れたリンク・存在しない見出しへのリンクがあると一覧を出して非ゼロで終わる(公開のワークフローも同じ所で止まる)
- 変換器の単体テストは `node --test Scripts/md2html/md2html.test.mjs`
