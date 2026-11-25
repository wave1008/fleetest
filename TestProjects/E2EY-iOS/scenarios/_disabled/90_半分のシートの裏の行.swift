// 90_半分のシートの裏の行.swift
// **陽性対照**(既定スイートには載せない): SwiftUI の半分のシートの裏の行への tap を、撃たずに断ることを DSL で確かめる。
// 回すのは Scripts/e2e-negative.sh(期待値は Scripts/negative-controls.json)。
// XCUITest の `isHittable` はこの行に true を返す(誤り)ので、inapp-boost モードの in-app の当たり判定(`/touchlands`)が
// 「対象に届かずシートに届く」と言い切ったときだけ断る(`TapTargetGeometry.touchLandsOnCoverInstead`・FD-2.1)。
// **S0010 は scene 4 の tap で落ちるのが正常**。緑になったら退行(in-app が人には押せない行を直接押している)。
// scene 2・3 は対照(見えている背面の行・シートの行は撃つ)
import FTDSL

@TestClass(platform: "ios")
class 半分のシートの裏の行 {

    @Test("半分のシートの裏の行を押すと断る(落ちるのが正常)")
    func S0010() {
        scenario {
            scene(1, "半分へ") {
                condition {
                    launchApp()
                    tap("#nav_player")
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
                    tap("#row_main_08")
                }.expectation {
                    select("#txt_player_result").textIs("player=main:row_main_08")
                }
            }
        }
    }
}
