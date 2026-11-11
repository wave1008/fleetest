// Scripts/regress.py(回帰を全マシンで1回の `fleetest run --target …` として回す包み)の約束を固定する:
// ①包みの SUT の表(SUITES)は各スクリプトの既定の SUT の一覧と同じ(片方だけ変えると対象が黙って欠ける・知らない SUT を撃つ)
// ②対象(プロジェクト:プロファイル)は各スクリプトが回すものと同じで、fleetest run の --target に並ぶ

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

const ROOT = resolve(import.meta.dirname, '../..')
const REGRESS = join(ROOT, 'Scripts/regress.py')

/** regress.py をモジュールとして読み込み、Python の式を評価して JSON で返す */
function py(expr) {
  const code = [
    'import importlib.util, json, sys',
    `spec = importlib.util.spec_from_file_location("regress", ${JSON.stringify(REGRESS)})`,
    'm = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)',
    `print(json.dumps(${expr}))`,
  ].join('\n')
  return JSON.parse(execFileSync('python3', ['-c', code], { encoding: 'utf8' }))
}

/** スクリプトの `[ -n "$SUTS" ] || SUTS="…"` の既定の一覧 */
function scriptSuts(script) {
  const source = readFileSync(join(ROOT, 'Scripts', script), 'utf8')
  const m = source.match(/\[ -n "\$SUTS" \] \|\| SUTS="([^"]+)"/)
  assert.ok(m, `${script} から既定の SUT の一覧を読めない`)
  return m[1].split(/\s+/).sort()
}

test('包みの SUT の表は各スクリプトの既定の SUT の一覧と同じ', () => {
  const suites = py('{k: [v[0], sorted(v[2].keys())] for k, v in m.SUITES.items()}')
  for (const [suite, [script, suts]] of Object.entries(suites)) {
    assert.deepEqual(suts, scriptSuts(script), `${suite}(${script})`)
  }
})

test('対象は SUT ごとに回す OS・モードの数だけでき、xcuitest は指定したときだけ足す', () => {
  const plain = py('[f"{p}:{q}" for _, p, q in m.build_targets(["e2ey"], False)]')
  assert.ok(plain.includes('E2EY-RN:ios-inapp-boost') && plain.includes('E2EY-RN:android'))
  assert.ok(!plain.some((k) => k.endsWith('ios-xcuitest')))
  assert.ok(!plain.includes('E2EY-Android:ios-inapp-boost'), 'Android だけの SUT に iOS の対象を作らない')
  const withXcui = py('[p for _, p, _ in m.build_targets(["e2ey"], True)]')
  assert.equal(withXcui.length - plain.length, 4, 'iOS を持つ 4 SUT に xcuitest の対象を1つずつ')
  const narrowed = py('[f"{p}:{q}" for _, p, q in m.build_targets(["e2e", "e2ex"], False, ["flutter"])]')
  assert.deepEqual(narrowed.sort(), ['E2E-Flutter:android', 'E2E-Flutter:ios-inapp-boost',
    'E2EX-Flutter:android', 'E2EX-Flutter:ios-inapp-boost'])
  const xcuiOnly = py('[f"{p}:{q}" for _, p, q in m.build_targets(["e2ey"], False, None, True)]')
  assert.deepEqual(xcuiOnly.sort(), ['E2EY-CMP:ios-xcuitest', 'E2EY-Flutter:ios-xcuitest',
    'E2EY-RN:ios-xcuitest', 'E2EY-iOS:ios-xcuitest'], 'xcuitest だけ = inapp-boost と Android を入れない')
})

test('対象のプロファイルはそのプロジェクトに実在する', () => {
  const all = py('[[p, q] for _, p, q in m.build_targets(["e2e", "e2ex", "e2ey"], True)]')
  for (const [project, profile] of all) {
    const path = join(ROOT, 'TestProjects', project, 'profiles', 'runs', `${profile}.json`)
    assert.ok(readFileSync(path, 'utf8').length > 0, path)
  }
})

/** Scripts/mark_exclusions.py をモジュールとして読み込み、式を評価して JSON で返す */
function exclusions(expr, setup = '') {
  const code = [
    'import importlib.util, json, os, sys, tempfile, time',
    `spec = importlib.util.spec_from_file_location("mx", ${JSON.stringify(join(ROOT, 'Scripts/mark_exclusions.py'))})`,
    'm = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)',
    setup,
    `print(json.dumps(${expr}))`,
  ].join('\n')
  return JSON.parse(execFileSync('python3', ['-c', code], { encoding: 'utf8' }))
}

test('印の条件から外す赤の表: 行は実在する対象・シナリオを指し、そのスイートの印を書くスクリプトが判定を呼ぶ', () => {
  const rows = exclusions('[list(k) + [v] for k, v in m.EXCLUSIONS.items()]')
  assert.ok(rows.length > 0)
  const targets = py('[[s, p, q] for s, p, q in m.build_targets(["e2e", "e2ex", "e2ey"], True)]')
  for (const [project, profile, sid, reason] of rows) {
    const target = targets.find(([, p, q]) => p === project && q === profile)
    assert.ok(target, `${project} / ${profile} は回帰の対象に無い`)
    assert.match(reason, /^OI-\d+$/, '理由は台帳の項目')
    const cls = sid.split('.')[0]
    const dir = join(ROOT, 'TestProjects', project, 'scenarios')
    const found = execFileSync('grep', ['-rl', `class ${cls} `, dir], { encoding: 'utf8' }).trim()
    assert.ok(found, `${sid} のクラスが ${dir} に無い`)
    const script = py(`m.SUITES[${JSON.stringify(target[0])}][0]`)
    // コメントにもファイル名が出るので、呼び出しの形(コメントを落とした行)で見る
    const code = readFileSync(join(ROOT, 'Scripts', script), 'utf8').split('\n').filter((l) => !/^\s*#/.test(l)).join('\n')
    assert.ok(code.includes('python3 "$ROOT/Scripts/mark_exclusions.py"'), `${script} が mark_exclusions.py を呼ばない = 行が効かない`)
  }
  const regress = readFileSync(REGRESS, 'utf8').split('\n').filter((l) => !/^\s*#/.test(l)).join('\n')
  assert.ok(regress.includes('mark_exclusions.excluded_reds('), 'regress.py が判定を呼ばない = 回帰で行が効かない')
})

test('外す赤の判定: 赤が全部表の行のときだけ名指しを返し、表に無い赤・記録の欠け・赤なしの失敗は言えない', () => {
  // 一時の root に run を1本作る(scenarios の赤の数と run.json の failed を合わせる・合わせない)
  const setup = `
root = tempfile.mkdtemp()
def make(project, profile, reds, passes=1, failed=None):
    d = os.path.join(root, "TestProjects", project, "results", "runs", "2026-11", f"r{time.time_ns()}")
    os.makedirs(os.path.join(d, "scenarios"))
    for i, sid in enumerate(reds):
        json.dump({"scenarioID": sid, "passed": False}, open(os.path.join(d, "scenarios", f"red{i}.json"), "w"))
    for i in range(passes):
        json.dump({"scenarioID": f"ok.S{i}", "passed": True}, open(os.path.join(d, "scenarios", f"ok{i}.json"), "w"))
    json.dump({"profile": profile, "failed": len(reds) if failed is None else failed}, open(os.path.join(d, "run.json"), "w"))
    return root
STICKY = "貼り付く見出しのリストを扱えること.S0010"
def case(name):
    global root
    root = tempfile.mkdtemp()
    if name == "only-excluded": make("E2EX-RN", "ios-xcuitest", [STICKY, STICKY])
    if name == "other-red": make("E2EX-RN", "ios-xcuitest", [STICKY, "他.S0010"])
    if name == "missing-record": make("E2EX-RN", "ios-xcuitest", [STICKY], failed=2)
    if name == "no-red": make("E2EX-RN", "ios-xcuitest", [])
    if name == "no-run": pass
    if name == "other-profile": make("E2EX-RN", "ios-xcuitest", [STICKY]); make("E2EX-RN", "android", [STICKY])
    return m.excluded_reds([("E2EX-RN", "ios-xcuitest")] + ([("E2EX-RN", "android")] if name == "other-profile" else []), 0, root)
`
  const got = exclusions('{n: case(n) for n in ["only-excluded", "other-red", "missing-record", "no-red", "no-run", "other-profile"]}', setup)
  assert.deepEqual(got['only-excluded'], [['E2EX-RN', 'ios-xcuitest', '貼り付く見出しのリストを扱えること.S0010', 'OI-216'],
    ['E2EX-RN', 'ios-xcuitest', '貼り付く見出しのリストを扱えること.S0010', 'OI-216']])
  assert.equal(got['other-red'], null, '表に無い赤が混ざれば外さない')
  assert.equal(got['missing-record'], null, 'run.json の failed と記録の赤が合わなければ言えない')
  assert.equal(got['no-red'], null, '赤の記録が無い失敗(シナリオの外の理由)は外さない')
  assert.equal(got['no-run'], null, 'run が無ければ言えない')
  assert.equal(got['other-profile'], null, '同じシナリオでも表に無いプロファイル(android)の赤は外さない')
})

test('fleetest run の引数: 対象ごとに --target・回帰は録画しない', () => {
  const args = py('m.run_args(m.build_targets(["e2e"], False, ["cmp"]))').slice(1)
  assert.deepEqual(args, ['run', '--target', 'E2E-CMP:ios-inapp-boost', '--target', 'E2E-CMP:android',
    '--set', 'record=false'])
})
