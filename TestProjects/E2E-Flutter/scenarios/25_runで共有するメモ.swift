// 25_runで共有するメモ.swift
// fleetest 機能: beforeAll(1回の run × クラスで1回・どのデバイスのシナリオより先)・afterAll(run × クラスで1回・
// 全デバイスの仕事の後)・setUpDevice(1回の run × デバイス × クラスで最大1回)と、
// writeRunMemo / readRunMemo / runMemoTextAs(run 全体・全デバイス・全マシンで共有)・writeMemo / readMemo(テスト1本の中だけ)。
// 3本がどのデバイスに配られても、beforeAll が先に走れば全部緑になる。別のデバイスのシナリオが beforeAll より先に
// 走ると、そのシナリオの readRunMemo("beforeAllRan") が "" で赤になる(待たせる仕組みの見張り)。
// beforeAll の2回実行の見張りは置かない(マシンをまたぐ run では run メモが共有されるので、別マシンの beforeAll の書き込みが見える)。
// tearDownDevice はデバイスの仕事の後に専用のプロセスで1回走る(合否には数えない)。**clearRunMemo() はしない** ——
// run メモは run 全体なので、先に終わったデバイスが消すと他のデバイスのシナリオが読めなくなる

import FTDSL

@TestClass
class runで共有するメモ {

    func beforeAll() {
        writeRunMemo("beforeAllRan", "yes")
        launchApp()
        tap("#nav_input")
        select("#txt_echo_single").runMemoTextAs("echo")
    }

    // デバイスごとに1回。run メモは run 全体なので、デバイスごとの回数は run メモでは見張れない(単体テストが見る)
    func setUpDevice() {
        launchApp()
    }

    // デバイスがシナリオを終えた後に1回(結果は run ログの「tearDownDevice of runで共有するメモ: passed」)
    func tearDownDevice() {
        readRunMemo("beforeAllRan").thisIs("yes")
    }

    // run の全デバイスの仕事が終わった後に専用のプロセスで1回(結果は run ログの「afterAll of runで共有するメモ: passed」)。
    // beforeAll とシナリオが書いた run メモを読める(片付けの経路でも run メモは run 全体)。scenarioRan は3本とも書く =
    // `--scenario` で一部だけ流す run でも成り立つ(S0020 だけが書く scratch を見ると、S0020 を含まない run で必ず赤になる)
    func afterAll() {
        readRunMemo("beforeAllRan").thisIs("yes")
        readRunMemo("scenarioRan").thisIs("yes")
    }

    @Test("beforeAll が書いた値を読める(1本目)")
    func S0010() {
        scenario {
            scene(1, "メモを読む") {
                action {
                    writeRunMemo("scenarioRan", "yes")
                }.expectation {
                    readRunMemo("beforeAllRan").thisIs("yes")
                    readRunMemo("echo").thisIs("single=")
                }
            }
        }
    }

    @Test("beforeAll が書いた値を読める(2本目)・メモはテスト1本の中だけで上書きは最後の値")
    func S0020() {
        scenario {
            scene(1, "メモを読んで書き足す") {
                action {
                    writeRunMemo("scenarioRan", "yes")
                    readMemo("scratch").thisIs("")
                    writeMemo("scratch", "a")
                    writeMemo("scratch", "b")
                }.expectation {
                    readRunMemo("beforeAllRan").thisIs("yes")
                    readMemo("scratch").thisIs("b")
                    readRunMemo("scratch").thisIs("")
                }
            }
        }
    }

    @Test("beforeAll が書いた値を読める(3本目)")
    func S0030() {
        scenario {
            scene(1, "メモを読む") {
                action {
                    writeRunMemo("scenarioRan", "yes")
                }.expectation {
                    readRunMemo("beforeAllRan").thisIs("yes")
                    readRunMemo("echo").thisIs("single=")
                }
            }
        }
    }
}
