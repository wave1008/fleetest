// 33_run全体の準備と片付け.swift
// fleetest 機能: @RunHooks の beforeRun / afterRun(DR-209・RR-8.4)。**E2E-CMP だけに置く**(5 SUT の共通契約には載せない)。
// beforeRun は1回の run × プロジェクトで1回、どのシナリオよりも前に走り、書いた run メモは全テストが最初の行から読める。
// afterRun は全マシンの仕事の後に走り、最終の値を読むだけ(afterRun の中の writeRunMemo は失敗になる仕様)。
// **E2E-CMP の全部の run で beforeRun が走る**ので、軽く保つ(run メモを書くだけ・デバイスのコマンドを書かない)。
// 「beforeRun が1回だけ走ったか」は run の後にログで見る(「beforeRun」の行が1回)。シナリオの中では見張れない

import FTDSL

@RunHooks
class run全体のフック {

    func beforeRun() {
        writeRunMemo("beforeRunRan", "yes")
    }

    // 結果は run ログの「afterRun: passed」。合否には数えない(読んだ値が違えば afterRun の失敗としてログに出る)
    func afterRun() {
        readRunMemo("beforeRunRan").thisIs("yes")
        // 35_ の排他ロックのカウンタの最後の値を run ログに残す(35_ を回した run では本数と同じ値。回していなければ空)
        readRunMemo("lockCounter")
    }
}
