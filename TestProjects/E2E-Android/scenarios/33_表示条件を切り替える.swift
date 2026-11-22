// 33_表示条件を切り替える.swift
// fleetest 機能: `setAppearance` / `setTextSize`(端末の外観・文字サイズをシナリオの途中で変える。docs/commands.md)。
// 契約: 表示条件画面(ライフサイクル画面の `#btn_open_display`)の `#txt_appearance`(`light` / `dark`)と
// `#txt_text_size`(OS の生の値。段階名への対応表は SUT に持たないので、変わったことだけ比べる。E2EAppCMP/docs/ui-contract.md)。
// S0020 は S0010 が `dark` / `extraLarge` にした端末でも、親が終わりに基準の状態(light / default)へ戻すので
// 基準の状態で始まることの陽性対照(どの端末で続けて走っても成り立つ)。
import FTDSL

@TestClass
class 表示条件を切り替えられること {

    @Test("setAppearance(.dark) と setTextSize(.extraLarge) がアプリへ届く。開始時は基準の状態")
    func S0010() {
        scenario {
            scene(1, "表示条件画面を開き、開始時は light であることを確かめて文字サイズを控える") {
                condition {
                    launchApp()
                    tap("#nav_lifecycle", scroll: .down)
                    tap("#btn_open_display", scroll: .down)
                }.action {
                    writeMemo("sizeAtStart", select("#txt_text_size").text ?? "")
                }.expectation {
                    select("#txt_appearance").textIs("light")
                }
            }
            scene(2, "setAppearance(.dark) でアプリの外観が dark になる") {
                action {
                    setAppearance(.dark)
                }.expectation {
                    // 外観の変化はアプリへ非同期に届くので、掴む側も待つ
                    select("#txt_appearance", waitSeconds: 10).textIs("dark", waitSeconds: 10)
                }
            }
            scene(3, "setTextSize(.extraLarge) で文字サイズの値が開始時から変わる") {
                action {
                    setTextSize(.extraLarge)
                    // Android はアプリの configChanges に fontScale が無いと画面が作り直され、RN はホームへ戻る(FD-2.7)。
                    // どの SUT でも同じ形で確かめるため、起動し直して開き直す(外観のその場の反映は scene 2 が確かめる)
                    launchApp()
                    tap("#nav_lifecycle", scroll: .down)
                    tap("#btn_open_display", scroll: .down)
                }.expectation {
                    select("#txt_text_size", waitSeconds: 10).textIsNot(readMemo("sizeAtStart"), waitSeconds: 10)
                }
            }
        }
    }

    @Test("前のシナリオが dark / extraLarge にしても、次のシナリオは基準の状態(light)で始まる")
    func S0020() {
        scenario {
            scene(1, "表示条件画面を開くと light") {
                condition {
                    launchApp()
                    tap("#nav_lifecycle", scroll: .down)
                    tap("#btn_open_display", scroll: .down)
                }.expectation {
                    select("#txt_appearance").textIs("light")
                }
            }
        }
    }
}
