// `npm test` に --test-force-exit を付けない。子はテストが終わった時点で process.exit し、パイプへ書き切れていない結果を
// 捨てる = 報告の件数と落ちたテストの名前が毎回違う位置で欠ける(終了コードは正しい)。MN-4.3

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

test("npm test は --test-force-exit を付けない", () => {
  const scripts = JSON.parse(readFileSync("package.json", "utf8")).scripts;
  assert.match(scripts.test, /node --test /,
    "package.json の scripts.test が `node --test ` を呼んでいない(このテストが見る形が崩れた。--test-force-exit を付けない規則が守られているか読み直す)");
  assert.doesNotMatch(scripts.test, /--test-force-exit/,
    "package.json の scripts.test から --test-force-exit を外す。付けると子が終了時にパイプの未送信分を捨て、報告の件数と落ちたテスト名が欠ける(MN-4.3。終わらないテストは付けて隠さず、閉じていないハンドルを閉じる)");
});
