// SUT の UI 契約ドリフト検出。
// 契約(CLAUDE.md): 要素の testTag/`#id`/ラベルの唯一の正は E2EAppCMP/docs/ui-contract.md(E2EX / E2EY は各 CMP の契約)。
// 各 SUT の <SUT>/docs/ui-contract.md には型語彙と OS/フレームワーク固有の罠だけを置く。
// SUT 側の契約が母体に無い `#id` を語り出すと、SUT 群が同じ画面契約を共有しているという前提が
// 静かに崩れ、シナリオがどの SUT で通るのか分からなくなる。
//
// 見るのは2方向: ①SUT 側に出る #id は母体にも在る(母体にあって SUT 側に出ない id は正常 = SUT 側は差分だけを書く)
// ②実在する SUT の契約ファイルと、このテストが検査する一覧が等しい(新しい SUT の契約が検査の外に残らない)。
//
// process.cwd() は npm test 実行時に vscode-fleetest ルート(protocolVersion.test.mjs と同じ前提)。

import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = path.join(process.cwd(), "..");
const FRAMEWORKS = ["IOS", "Android", "Flutter", "RN"];

// 系統ごとの母体(複数ファイルでもよい)と SUT 側の契約。母体は E2E<X>AppCMP/docs/ui-contract*.md
const FAMILIES = ["E2E", "E2EX", "E2EY"].map((prefix) => ({
  prefix,
  masters: readdirSync(path.join(ROOT, `${prefix}AppCMP`, "docs"))
    .filter((f) => /^ui-contract.*\.md$/.test(f))
    .map((f) => `${prefix}AppCMP/docs/${f}`)
    .sort(),
  suts: FRAMEWORKS.map((fw) => `${prefix}App${fw}/docs/ui-contract.md`),
}));

const ID_PATTERN = /#[a-z][a-z0-9_]*/g;

// 母体に宣言が無い #id の許可表。**理由を書けないものは足さない**。
// 接頭辞だけの断片(`#otp_box_N`・`#item_*` を正規表現が `#otp_box_` と拾う)と、そのフレームワークにだけある id
const UNDECLARED_ALLOWED = {
  "E2EXAppAndroid/docs/ui-contract.md": ["#field_search_input", "#opt_fruit_"],   // Android だけの検索欄 / 「`#opt_fruit_*` は存在しない」の断片
  "E2EXAppFlutter/docs/ui-contract.md": ["#btn_hero", "#btn_hero_back", "#item_"],   // Hero の遷移を担う別ボタン(Flutter だけ)/ 断片
  "E2EXAppRN/docs/ui-contract.md": ["#range_slider_max", "#range_slider_min"],   // RN に範囲スライダーが無く2本で代える
  "E2EYAppFlutter/docs/ui-contract.md": ["#otp_box_"],   // 断片
  "E2EYAppRN/docs/ui-contract.md": ["#otp_box_", "#tab_"],   // 断片
};

/**
 * 母体が宣言する id 集合。`#row_01` … `#row_40` のような連番の範囲記法を展開する
 * (展開しないと `#row_03` を参照する SUT 契約が誤検出になる)。
 */
function declaredIDs(source) {
  const ids = new Set(source.match(ID_PATTERN) ?? []);
  const rangePattern = /#([a-z][a-z0-9_]*?)_(\d+)`?\s*…\s*`?#\1_(\d+)/g;
  for (const [, prefix, from, to] of source.matchAll(rangePattern)) {
    const width = from.length;
    for (let n = Number(from); n <= Number(to); n++) {
      ids.add(`#${prefix}_${String(n).padStart(width, "0")}`);
    }
  }
  return ids;
}

const read = (rel) => readFileSync(path.join(ROOT, rel), "utf8");
const declaredByMasters = (masters) => declaredIDs(masters.map(read).join("\n"));

test("母体 ui-contract から id を抽出でき、連番の範囲記法が展開される", () => {
  const master = declaredByMasters(FAMILIES[0].masters);
  assert.ok(master.size > 0, `${FAMILIES[0].masters} から #id を抽出できません`);
  // 範囲記法の展開が効いていること(効かないと下のテストが誤検出になる)
  assert.ok(
    master.has("#row_01") && master.has("#row_40"),
    "E2EAppCMP/docs/ui-contract.md の連番範囲(#row_01 … #row_40)を展開できていません",
  );
});

for (const family of FAMILIES) {
  test(`${family.prefix}: 実在する SUT の契約ファイルが検査の一覧と等しい`, () => {
    const actual = readdirSync(ROOT)
      .filter((d) => new RegExp(`^${family.prefix}App(?!CMP$)[A-Za-z]+$`).test(d))
      .map((d) => `${d}/docs/ui-contract.md`)
      .filter((f) => existsSync(path.join(ROOT, f)))
      .sort();
    assert.ok(family.masters.length > 0, `${family.prefix}AppCMP/docs に契約(母体)が無い`);
    assert.deepEqual(
      actual,
      [...family.suts].sort(),
      `${family.prefix} の SUT の契約ファイルと FRAMEWORKS/FAMILIES の一覧が食い違っています。` +
        "新しい SUT を足したら FRAMEWORKS に足し、消したらここからも消すこと",
    );
  });

  for (const contract of family.suts) {
    test(`${contract} の #id はすべて母体 ui-contract に存在する`, () => {
      const master = declaredByMasters(family.masters);
      const used = new Set(read(contract).match(ID_PATTERN) ?? []);
      assert.ok(used.size > 0, `${contract} から #id を抽出できません(走査の形が変わった)`);

      const allowed = new Set(UNDECLARED_ALLOWED[contract] ?? []);
      const unknown = [...used].filter((id) => !master.has(id) && !allowed.has(id)).sort();
      assert.deepEqual(
        unknown,
        [],
        `${contract} が母体に無い #id を参照しています: ${unknown.join(", ")}\n` +
          `要素の testTag/#id/ラベルの唯一の正は ${family.masters.join(" / ")} です。` +
          "id を足すならまず母体に足し、SUT 側には型語彙と固有の罠だけを書くこと",
      );
      // 許可表の行が古くなっていない(母体へ足した / SUT 側から消した id は表から消す)
      const stale = [...allowed].filter((id) => !used.has(id) || master.has(id));
      assert.deepEqual(stale, [], `UNDECLARED_ALLOWED の ${contract} に不要な行: ${stale.join(", ")}`);
    });
  }
}
