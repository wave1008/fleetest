// Scripts/sut-rebuild.sh の RN 向け検査: codegen の登録表(RCTThirdPartyComponentsProvider.mm)が空なら
// ①needs_rebuild が真 ②rn_assert_provider_registered が失敗を返す。空だと Fabric 部品が登録されず起動直後に落ちる。

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, mkdirSync, writeFileSync, utimesSync, chmodSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'

const ROOT = resolve(import.meta.dirname, '../..')
const GEN = 'ios/build/generated/ios/ReactCodegen'

const table = (entries) => `@implementation X
    thirdPartyComponents = @{
${entries.map((n) => `\t@"${n}": NSClassFromString(@"${n}View"), // lib`).join('\n')}
    };
@end
`

/** provider: null = ファイル無し / 文字列 = 内容 */
function fixture({ provider, rn = true }) {
  const dir = mkdtempSync(join(tmpdir(), 'sut-rn-'))
  const app = join(dir, 'App')
  mkdirSync(join(app, 'src'), { recursive: true })
  mkdirSync(join(app, 'ios'), { recursive: true })
  mkdirSync(join(app, 'dist/ios-simulator/X.app'), { recursive: true })
  writeFileSync(join(app, 'package.json'), rn ? '{"dependencies":{"react-native":"1"}}' : '{}')
  writeFileSync(join(app, 'src/a.ts'), '')
  const old = new Date(Date.now() - 3600_000)
  utimesSync(join(app, 'src/a.ts'), old, old)
  if (provider !== null) {
    mkdirSync(join(app, GEN), { recursive: true })
    writeFileSync(join(app, GEN, 'RCTThirdPartyComponentsProvider.mm'), provider)
  }
  // .app は Xcode のビルド番号の控えも見る。偽の xcodebuild と同じ番号の控えを置いて SDK の軸を立てない
  const bin = join(dir, 'bin')
  mkdirSync(bin)
  writeFileSync(join(bin, 'xcodebuild'), "#!/bin/sh\nprintf 'Xcode 99.0\\nBuild version 99A1\\n'\n")
  chmodSync(join(bin, 'xcodebuild'), 0o755)
  const artifact = join(app, 'dist/ios-simulator/X.app')
  writeFileSync(`${artifact}.sdk`, 'xcode 99A1\n')
  return { app, artifact, bin }
}

function sh(body, bin = '/nonexistent-bin') {
  const r = spawnSync('bash', ['-c', `set -uo pipefail\nFORCE_REBUILD=0\n. ${JSON.stringify(join(ROOT, 'Scripts/sut-rebuild.sh'))}\n${body}`], {
    encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}` },
  })
  return { code: r.status, out: r.stdout.trim(), err: r.stderr }
}
const needs = (fx) => sh(`if needs_rebuild ${JSON.stringify(fx.artifact)} ${JSON.stringify(join(fx.app, 'src'))}; then echo yes; else echo no; fi`, fx.bin).out
const assertCode = (fx) => sh(`rn_assert_provider_registered ${JSON.stringify(fx.app)}`)

test('登録表が空なら作り直し・検査は失敗する', () => {
  const fx = fixture({ provider: table([]) })
  assert.equal(needs(fx), 'yes')
  const r = assertCode(fx)
  assert.equal(r.code, 1)
  assert.match(r.err, /登録表が空/)
})

test('1行に潰れた空の登録表(@{ })も空として扱う', () => {
  const fx = fixture({ provider: 'thirdPartyComponents = @{ };\n' })
  assert.equal(needs(fx), 'yes')
  assert.equal(assertCode(fx).code, 1)
})

test('ファイルが無ければ作り直し・検査は失敗する', () => {
  const fx = fixture({ provider: null })
  assert.equal(needs(fx), 'yes')
  assert.equal(assertCode(fx).code, 1)
})

test('登録が1件以上あれば作り直さず・検査は通る', () => {
  const fx = fixture({ provider: table(['RNSFullWindowOverlay']) })
  assert.equal(needs(fx), 'no')
  assert.equal(assertCode(fx).code, 0)
})

test('RN でない SUT には当てない(登録表が無くても mtime だけで判定)', () => {
  const fx = fixture({ provider: null, rn: false })
  assert.equal(needs(fx), 'no')
})
