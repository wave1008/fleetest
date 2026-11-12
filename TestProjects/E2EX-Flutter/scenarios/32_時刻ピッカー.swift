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
                    // showTimePicker の OK/Cancel には #id を付けられない(アプリは英語の既定のまま)
                    tap("OK")
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
                    tap("Cancel")
                }.expectation {
                    select("#txt_time_result").textIs("time=cancel")
                    notExist("OK")
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
                        tap("Switch to text input mode")
                        type(".textField[1]", "14", replace: true)
                        type(".textField[2]", "45", replace: true)
                        tap("OK")
                    }
                }.expectation {
                    android { select("#txt_time_result").textIs("time=14:45") }
                }
            }
        }
    }
}
