// 34_run全体の準備を読む.swift
// 33_run全体の準備と片付け.swift の beforeRun が書いた run メモを、どのデバイス・どのマシンのどのテストも
// 最初の行から読めること(beforeRun は全シナリオの開始前に確定する)。

import FTDSL

@TestClass
class run全体の準備を読む {

    @Test("beforeRun が書いた値を読める(1本目)")
    func S0010() {
        scenario {
            scene(1, "run メモを読む") {
                expectation {
                    readRunMemo("beforeRunRan").thisIs("yes")
                }
            }
        }
    }

    @Test("beforeRun が書いた値を読める(2本目)")
    func S0020() {
        scenario {
            scene(1, "run メモを読む") {
                expectation {
                    readRunMemo("beforeRunRan").thisIs("yes")
                }
            }
        }
    }
}
