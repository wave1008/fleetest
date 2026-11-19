// 28_runメモをマシンをまたいで共有する.swift
// run メモ(DR-208)がマシンをまたいで1つであることの陽性対照。**E2E-CMP だけに置く**(5 SUT の共通契約には載せない)。
// 各テストは前のテストが書いた「書き手のホスト名 | 大きな値」を読み、自分の分を書き足す。後から加わったマシンの最初のテストは
// 別のマシンのテストが書いた値を読むので、中継が効いていれば「読んだ書き手 ≠ 自分のホスト」のテストが必ず出る。
// その判定はシナリオの中では行わず(どのテストが最初かは決まらない)、run の後に結果で行う
// (Scripts/check-run-memo-cross-machine.py。各テストは読んだ書き手と自分のホストを writeMemo の記述に残す)。
// 各テストの中で見るのは、届いた値が壊れていないこと(端末を通る経路で大きな値・多数の行が欠けない)だけ。
// 1台のマシンだけの run でも緑になる

import Foundation
import FTDSL

/// このシナリオが走っているマシンのホスト名(マシンを見分けるだけに使う)
private func currentHost() -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    gethostname(&buffer, buffer.count)
    return String(cString: buffer)
}

/// 1 KB を大きく超える値(端末の行の上限を超えるので、分割して届くことを見る)
private let largeValue = String(repeating: "あいうえお0123456789", count: 120)

private let keyCount = 40

@TestClass
class runメモをマシンをまたいで共有する {

    // マシンごとに1回走る。多数の行を一度に流す(どのマシンの beforeAll も同じ値を書く = どれが届いても同じ検証が通る)
    func beforeAll() {
        for index in 0..<keyCount {
            writeRunMemo("key\(index)", "v\(index)")
        }
    }

    @Test("書き手を記録する(1本目)")
    func S0010() { recordWriter() }

    @Test("書き手を記録する(2本目)")
    func S0020() { recordWriter() }

    @Test("書き手を記録する(3本目)")
    func S0030() { recordWriter() }

    @Test("書き手を記録する(4本目)")
    func S0040() { recordWriter() }

    @Test("書き手を記録する(5本目)")
    func S0050() { recordWriter() }

    @Test("書き手を記録する(6本目)")
    func S0060() { recordWriter() }

    private func recordWriter() {
        scenario {
            scene(1, "前のテストが書いた値を読み、自分の分を書き足す") {
                action {
                    let last = readRunMemo("lastTest")
                    // 記述に値が残る(結果の events の step.description)。run の後の検査がこの2行を読む
                    writeMemo("readWriterHost", last.components(separatedBy: "|").first ?? "")
                    writeMemo("ownHost", currentHost())
                    writeMemo("readPayload", last.isEmpty ? largeValue : String(last.drop(while: { $0 != "|" }).dropFirst()))
                    writeRunMemo("lastTest", currentHost() + "|" + largeValue)
                    // 1本を長くして、先に用意のできたマシンが全部を取り切らないようにする(後から加わるマシンにも配られる)。
                    // 根拠: 2026-11-20 の1回目は1本約4秒で、リモートのデバイスが加わる前に手元が6本を取り切り判定できなかった
                    wait(15)
                }.expectation {
                    readMemo("readPayload").thisIs(largeValue)
                    readRunMemo("key\(keyCount - 1)").thisIs("v\(keyCount - 1)")
                }
            }
        }
    }
}
