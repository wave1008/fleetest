// ライブ操作の serve へ ref を送らないことの走査。serve(Sources/fleetest/ApiLiveCommand.swift の knownKeys)は
// ref を受けず、ref の付いた行は撃たずに断る(ref で撃つのは MCP だけ。拡張は座標で撃つ)。
// 型(LiveServeCommand)は src の TS しか守らないので、ホスト側の全 .ts で serve の命令に ref が付いていないかを見る。
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const SRC = path.join(process.cwd(), "src");

test("ホスト側のソースは serve の命令に ref を付けない", () => {
  const files = readdirSync(SRC).filter((name) => name.endsWith(".ts"));
  assert.ok(files.includes("monitorLiveController.ts"), "走査が src に届いていない");
  const hits = [];
  for (const name of files) {
    const text = readFileSync(path.join(SRC, name), "utf8");
    for (const match of text.matchAll(/\{\s*(?:readonly\s+)?cmd:\s*"[A-Za-z]+"[^{}]*\bref\??:/g)) {
      hits.push(`${name}: ${match[0].replace(/\s+/g, " ")}`);
    }
  }
  assert.deepEqual(hits, [], "serve の命令に ref を付けない(serve は断る)");
});
