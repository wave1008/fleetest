// 35_runロックで数を数える.swift
// fleetest 機能: run 全体の排他ロック(withExclusiveLock。DR-210・RR-8.5)。**E2E-CMP だけに置く**(5 SUT の共通契約には載せない)。
// 4本のテストが同じキーの排他ロックの中で run メモのカウンタを「読む → 1秒待つ → 1を足して書く」。並列に走っても
// 足した分が消えないので、最後の値はテストの本数と同じになる(ロックを外すと、読んでから書くまでの1秒の間に別のテストが
// 同じ値を読み、足した分が消える)。最後の値は 33_ の afterRun が読んで run ログに出す(readRunMemo "lockCounter" → "4")。
// 振り直し(再実行)があると本体がもう一度走り、値が本数より大きくなる

import FTDSL

@TestClass
class runロックで数を数える {

    private func countUp() {
        withExclusiveLock("lockCounter") {
            let current = Int(readRunMemo("lockCounter")) ?? 0
            wait(1.0)
            writeRunMemo("lockCounter", String(current + 1))
        }
    }

    @Test("排他ロックの中でカウンタを足す(1本目)")
    func S0010() {
        scenario {
            scene(1, "カウンタを足す") { action { countUp() } }
        }
    }

    @Test("排他ロックの中でカウンタを足す(2本目)")
    func S0020() {
        scenario {
            scene(1, "カウンタを足す") { action { countUp() } }
        }
    }

    @Test("排他ロックの中でカウンタを足す(3本目)")
    func S0030() {
        scenario {
            scene(1, "カウンタを足す") { action { countUp() } }
        }
    }

    @Test("排他ロックの中でカウンタを足す(4本目)")
    func S0040() {
        scenario {
            scene(1, "カウンタを足す") { action { countUp() } }
        }
    }
}
