// モニター webview ⇄ 拡張のメッセージ契約(monitorWebviewMessages.ts)の type 集合を突き合わせるソース走査。
// webview は JS なので union 型の検査が効かず、手書きの検証器 isMonitorFromWebviewMessage と main.js の
// switch は union と別に手で保たれている。片側だけに足した/消した type をここで落とす。
// 走査は正規表現なので、union の書式(`readonly type: "x"`)・検証器の書式(`case "x":`)・
// main.js の書式(`case 'x':`)を変えたら、ここも直す(各集合の下限の件数で走査の空振りを止める)。

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";

const read = (rel) => fs.readFileSync(path.resolve(rel), "utf8");

/** `start` から次のトップレベル宣言(export / doc コメント / function)の手前までを返す。 */
function declarationBlock(source, start) {
  const i = source.indexOf(start);
  assert.notEqual(i, -1, `${start} が見つからない`);
  const rest = source.slice(i + start.length);
  const end = rest.search(/\n(export |\/\*\*|function )/);
  return end === -1 ? rest : rest.slice(0, end);
}

const typesIn = (block, pattern) => new Set([...block.matchAll(pattern)].map((m) => m[1]));

const messagesSource = read("src/monitorWebviewMessages.ts");

function fromWebviewUnion() {
  return typesIn(declarationBlock(messagesSource, "export type MonitorFromWebviewMessage ="), /readonly type: "(\w+)"/g);
}

function validatorCases() {
  const start = messagesSource.indexOf("export function isMonitorFromWebviewMessage");
  assert.notEqual(start, -1);
  const end = messagesSource.indexOf("\n}\n", start);
  return typesIn(messagesSource.slice(start, end), /case "(\w+)":/g);
}

function webviewSources() {
  const dir = path.resolve("src/webview");
  return fs.readdirSync(dir, { recursive: true })
    .filter((f) => f.endsWith(".js"))
    .map((f) => fs.readFileSync(path.join(dir, f), "utf8"));
}

const difference = (a, b) => [...a].filter((x) => !b.has(x)).sort();

test("webview→拡張: union の type と検証器の case が一致する", () => {
  const union = fromWebviewUnion();
  const cases = validatorCases();
  assert.ok(union.size >= 50, `union の走査が空振りしている (${union.size})`);
  assert.deepEqual(difference(cases, union), [], "検証器にだけある case(型にも送り手にも無い = 死んだ case)");
  assert.deepEqual(difference(union, cases), [], "union にあるのに検証器が通さない type(拡張が黙って捨てる)");
});

test("webview→拡張: union の type はどれも webview のどこかで組み立てられている", () => {
  const union = fromWebviewUnion();
  const literals = new Set();
  for (const source of webviewSources()) {
    for (const m of source.matchAll(/type:\s*'(\w+)'/g)) literals.add(m[1]);
  }
  assert.deepEqual(difference(union, literals), [], "送り手の無い type");
});

test("webview→拡張: webview が直接 postMessage する type はモニターかダッシュボードの union に載っている", () => {
  const dashboard = typesIn(declarationBlock(read("src/dashboardModel.ts"), "export type DashboardFromWebviewMessage ="),
    /type: "(\w+)"/g);
  const known = new Set([...fromWebviewUnion(), ...dashboard]);
  const sent = new Set();
  for (const source of webviewSources()) {
    for (const m of source.matchAll(/postMessage\(\{\s*type:\s*'(\w+)'/g)) sent.add(m[1]);
  }
  assert.ok(sent.size >= 50, `送り手の走査が空振りしている (${sent.size})`);
  assert.deepEqual(difference(sent, known), [], "型に載っていない type を送っている");
});

test("拡張→webview: MonitorToWebviewMessage の type はどれも main.js の switch が受ける", () => {
  const union = typesIn(declarationBlock(messagesSource, "export type MonitorToWebviewMessage ="), /readonly type: "(\w+)"/g);
  const main = read("src/webview/monitor/main.js");
  const switchAt = main.indexOf("switch (message.type) {");
  assert.notEqual(switchAt, -1);
  const handled = typesIn(main.slice(switchAt), /case '(\w+)':/g);
  assert.ok(union.size >= 40, `union の走査が空振りしている (${union.size})`);
  assert.deepEqual(difference(union, handled), [], "main.js が受けない type(webview が黙って捨てる)");
});
