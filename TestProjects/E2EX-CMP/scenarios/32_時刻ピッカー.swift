// 32_時刻ピッカー.swift
// 確かめる癖: 時刻ピッカー(ダイアログ・時計の文字盤は描画だけで要素が細かい)。

import FTDSL

@TestClass
class 時刻ピッカーで時刻を確定できること {

    @Test("初期値のまま OK")
    func S0010() {
        scenario {
            scene(1, "開いて OK") {
                condition {
                    launchApp()
                    tap("#nav_time", scroll: .down)
                }.action {
                    tap("#btn_open_time")
                    tap("#btn_time_ok")
                }.expectation {
                    select("#txt_time_result").textIs("time=09:30")
                }
            }
        }
    }

    @Test("キャンセル")
    func S0020() {
        scenario {
            scene(1, "開いてキャンセル") {
                condition {
                    launchApp()
                    tap("#nav_time", scroll: .down)
                }.action {
                    tap("#btn_open_time")
                    tap("#btn_time_cancel")
                }.expectation {
                    select("#txt_time_result").textIs("time=cancel")
                    notExist("#btn_time_ok")
                }
            }
        }
    }

    /// Android の時計の文字盤の時刻ピッカーを 14:45 に合わせる書き方(docs/user-docs/reference/writing/ui_component_patterns の時刻ピッカー)
    @Test("Android で 14:45 に合わせる")
    func S0030() {
        scenario {
            scene(1, "開いて 14:45 にして OK") {
                condition {
                    launchApp()
                    tap("#nav_time", scroll: .down)
                }.action {
                    android { tap("#btn_open_time") }
                    android {
                        tap("#btn_time_mode_toggle")
                        // 数字入力は焦点のある側だけが入力欄(もう片方は選ぶ部品)。分を選ぶと入力欄が分へ入れ替わる
                        type(".textField", "14", replace: true)
                        tap(".checkBox")
                        type(".textField", "45", replace: true)
                        tap("#btn_time_ok")
                    }
                }.expectation {
                    android { select("#txt_time_result").textIs("time=14:45") }
                }
            }
        }
    }
}
