// 91_半分のシートの裏の行の名指し.swift
// **陽性対照**(既定スイートには載せない): Android の Flutter の debug ビルドで、半分のシートの裏の行への tap の後の赤が
// 手前のシートの行を名指すことを確かめる(DR-235)。木の z はシートを奥と言うので、名指しの材料はアプリの VM サービスの塗り順だけ。
// 回すのは Scripts/e2e-negative.sh(期待値は Scripts/negative-controls.json)。
// **S0010 は scene 4 の検証で落ちるのが正常**(tap がシートの行に当たる)。赤の文言が覆いを名指さなくなったら退行。
// scene 2・3 は対照(見えている背面の行・シートの行は押せる)
import FTDSL

@TestClass(platform: "android")
class 半分のシートの裏の行の名指し {

    @Test("半分のシートの裏の行を押すと、赤の文言が手前のシートの行を名指す(落ちるのが正常)")
    func S0010() {
        scenario {
            scene(1, "半分へ") {
                condition {
                    launchApp()
                    tap("#nav_player", scroll: .down)
                    select("#txt_sheet_state", waitSeconds: 5).textIs("sheet=collapsed")
                }.action {
                    tap("#txt_mini_title")
                }.expectation {
                    select("#txt_sheet_state", waitSeconds: 5).textIs("sheet=half")
                }
            }
            scene(2, "見えている背面の行(対照)") {
                action {
                    tap("#row_main_01")
                }.expectation {
                    select("#txt_player_result").textIs("player=main:row_main_01")
                }
            }
            scene(3, "シートの行(対照)") {
                action {
                    tap("#queue_row_01")
                }.expectation {
                    select("#txt_player_result").textIs("player=queue:queue_row_01")
                }
            }
            scene(4, "シートの裏の背面の行") {
                action {
                    tap("#row_main_10")
                }.expectation {
                    select("#txt_player_result").textIs("player=main:row_main_10")
                }
            }
        }
    }
}
