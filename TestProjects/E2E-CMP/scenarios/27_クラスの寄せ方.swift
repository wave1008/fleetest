import FTDSL

// クラスの実行の寄せ方(RR-8.3)の陽性対照。**E2E-CMP だけに置く**(5 SUT の共通契約には載せない)。
// 順番は関数名の順と逆にしてある(S0030 → S0010 → S0020)= @Order が効いていなければ readRunMemo が赤になる。
// どのマシン・デバイスで走ったかは結果 JSON の machine / worker で見る(シナリオからは見えない)。
// **run メモのキーは OS ごとに分ける**: 回帰(`run --target`)はプロジェクトごとに run メモを1つにし、android と iOS の対象で共有する。
// 同じキーだと、並行して走る他方の OS の1本目の「1」が、こちらの2本目と3本目の間に割り込む(11/21 の回帰で実際に赤)

/// この OS 専用の run メモのキー
private func 順の印(_ name: String) -> String {
    var key = name
    ios { key += "-ios" }
    android { key += "-android" }
    return key
}

@RunInOrder("順番の保証の陽性対照")
@TestClass
class 順に流すクラス {

    @Order(10)
    @Test("1番目: 印を書く")
    func S0030() {
        scenario {
            scene(1, "印を書く") {
                action {
                    writeRunMemo(順の印("inOrderStep"), "1")
                }.expectation {
                    readRunMemo(順の印("inOrderStep")).thisIs("1")
                }
            }
        }
    }

    @Order(20)
    @Test("2番目: 1番目の印を読んで書き足す")
    func S0010() {
        scenario {
            scene(1, "前の印を読む") {
                action {
                    writeRunMemo(順の印("inOrderSeen2"), readRunMemo(順の印("inOrderStep")))
                    writeRunMemo(順の印("inOrderStep"), "2")
                }.expectation {
                    readRunMemo(順の印("inOrderSeen2")).thisIs("1")
                }
            }
        }
    }

    @Order(30)
    @Test("3番目: 2番目の印を読む")
    func S0020() {
        scenario {
            scene(1, "前の印を読む") {
                action {
                    writeRunMemo(順の印("inOrderSeen3"), readRunMemo(順の印("inOrderStep")))
                }.expectation {
                    readRunMemo(順の印("inOrderSeen3")).thisIs("2")
                }
            }
        }
    }
}

@RunOnSingleDevice("1台で1本ずつの陽性対照")
@TestClass
class 一台で流すクラス {

    @Test("1本目")
    func S0010() { scenario { scene(1, "書く") { action { writeMemo("singleDevice1", "y") }.expectation { readMemo("singleDevice1").thisIs("y") } } } }

    @Test("2本目")
    func S0020() { scenario { scene(1, "書く") { action { writeMemo("singleDevice2", "y") }.expectation { readMemo("singleDevice2").thisIs("y") } } } }

    @Test("3本目")
    func S0030() { scenario { scene(1, "書く") { action { writeMemo("singleDevice3", "y") }.expectation { readMemo("singleDevice3").thisIs("y") } } } }
}

@RunOnSingleMachine("1台のマシンに寄せる陽性対照")
@TestClass
class 一台のマシンで流すクラス {

    @Test("1本目")
    func S0010() { scenario { scene(1, "書く") { action { writeMemo("singleMachine1", "y") }.expectation { readMemo("singleMachine1").thisIs("y") } } } }

    @Test("2本目")
    func S0020() { scenario { scene(1, "書く") { action { writeMemo("singleMachine2", "y") }.expectation { readMemo("singleMachine2").thisIs("y") } } } }

    @Test("3本目")
    func S0030() { scenario { scene(1, "書く") { action { writeMemo("singleMachine3", "y") }.expectation { readMemo("singleMachine3").thisIs("y") } } } }

    @Test("4本目")
    func S0040() { scenario { scene(1, "書く") { action { writeMemo("singleMachine4", "y") }.expectation { readMemo("singleMachine4").thisIs("y") } } } }
}
