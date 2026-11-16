# Security Policy

[日本語](#日本語)

## Supported versions

fleetest is in beta. Only the **latest release tag** receives security fixes. Older tags are not patched — update to the latest release.

## Reporting a vulnerability

Please **do not open a public issue** for a security problem.

Report it privately from the repository's **Security** tab → **Report a vulnerability**
(<https://github.com/wave1008/fleetest/security/advisories/new>). Only you, the maintainer, and anyone the maintainer invites to help fix it can see the report.

Include what you can: the output of `fleetest --version`, macOS / Xcode versions, steps to reproduce, and the impact you expect.

## What to expect

Reports are handled on a best-effort basis: there is no guaranteed response time and no bug bounty. When a report is confirmed, the fix ships in a new release and the advisory is published with credit to you, unless you prefer otherwise.

## Scope

In scope, for example:

- Escaping the sandbox that fleetest runs scenario binaries in
- The MCP server, CLI, or device bridges letting someone perform operations they should not be able to
- The install and update flow running or fetching something other than what it claims
- Remote execution over SSH exposing credentials or running commands on the wrong machine

Out of scope:

- The apps and scenario projects fleetest uses to test itself and for the quick start (`E2E*App*/`, `TestProjects/`) — they are test targets, not part of the tool
- Issues that require already running code as the same macOS user (for example, other local processes reaching a bridge that listens only on loopback)
- Vulnerabilities in third-party dependencies with no demonstrated impact on fleetest — please report those upstream

---

## 日本語

**セキュリティの問題は公開の Issue に書かないでください。**

リポジトリの **Security** タブ → **Report a vulnerability**
(<https://github.com/wave1008/fleetest/security/advisories/new>)から非公開で報告してください。報告を見られるのは、あなたと保守者、保守者が修正のために招いた人だけです。

- 修正の対象は**最新のリリースタグだけ**です(ベータ版のため、古いタグには修正を出しません)。
- 対応はできる範囲で行い、回答の期限や報奨金はありません。
- 報告には、`fleetest --version` の出力・macOS と Xcode の版・再現手順・想定される影響を、分かる範囲で書いてください。
- 確認できた報告は新しいリリースで修正し、advisory を(希望しない場合を除き)あなたの名前付きで公開します。
- 範囲外: fleetest が自身のテストとクイックスタートに使うアプリとシナリオのプロジェクト(`E2E*App*/`・`TestProjects/`)・同じ macOS ユーザーとしてコードを実行できることが前提の問題(例: 同じ Mac の別のプロセスがループバックだけで待ち受けるブリッジに届く)・fleetest への影響を示せない依存の脆弱性(上流へ報告してください)。
- 範囲の例は、上の英語の **Scope** を見てください。
