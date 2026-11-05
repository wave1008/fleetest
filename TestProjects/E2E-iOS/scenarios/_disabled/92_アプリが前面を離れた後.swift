// **陽性対照(S0010〜S0040・S0060 は赤が正解・S0050 は緑)**。緑の run ではまず通らない経路を強制的に通す台なので、
// 通常実行に載せる `scenarios/` 直下には置かない。iOS の inapp-boost モードだけで意味がある(xcuitest モードはランナーが自分で断る)。
//
// 守っているもの: アプリが前面を離れた後(`home()` / `appSwitcher()`)の読み・操作を、人には触れない画面へ届けずに断る。
// - `home()` の直後に待たずに読む・押す: ランナーの /home は inapp-boost ではアプリが外れたかを確かめずに返り、直後の約 0.45 秒は
//   前面の照会が「前面」と答えたまま in-app が inactive で読み・操作を受けて緑・ボタンが押されていた(18周目 im4 F2/F3)。
//   `AppAttachDriver.home` が外れるのを待つ。赤は `app-in-background`
// - `appSwitcher()` の後: アプリは inactive のままなので in-app は断れず、カードの中のボタンが押されて緑だった(17周目 ilocal F1)。
//   撃つ前に XCUITest の覆いの照会でスイッチャーを確かめる。赤は `system-ui-covered`
// - 誤って断らない側: スイッチャーから `tapAppIcon()` で戻った後の操作は緑(S0050)
// - スイッチャーから `home()`: Simulator ではアプリへ戻り、前面のまま ✅ を返して後続の tap が押されていた(19周目 im4 F2)。
//   `AppAttachDriver.home` が押し直してホームへ出す。赤は `app-in-background`(S0060)
//
// **緑なら断りが効いていない**(押されたか読めた = 誤った成功)。赤でも failureKind が違えば別の経路で落ちている。
//
// 回し方: Scripts/e2e-negative.sh --project E2E-iOS --file 92_アプリが前面を離れた後.swift

import FTDSL

@TestClass(platform: "ios")
class アプリが前面を離れた後 {

    @Test("home の直後に待たずに読むと、背面と言って赤")
    func S0010() {
        scenario {
            scene(1, "home の直後に読む") {
                condition {
                    launchApp()
                }.action {
                    home()
                }.expectation {
                    exist("#txt_home_marker", waitSeconds: 2)
                }
            }
        }
    }

    @Test("home の直後に待たずに押すと、背面と言って赤")
    func S0020() {
        scenario {
            scene(1, "home の直後に押す") {
                condition {
                    launchApp()
                    tap("#nav_lifecycle", scroll: .down)
                }.action {
                    home()
                    tap("#btn_session_inc")
                }.expectation {
                    select("#txt_session_count").textIs("session=1")
                }
            }
        }
    }

    @Test("appSwitcher の後に押すと、スイッチャーと言って赤")
    func S0030() {
        scenario {
            scene(1, "スイッチャーの間に押す") {
                condition {
                    launchApp()
                    tap("#nav_lifecycle", scroll: .down)
                }.action {
                    appSwitcher()
                    tap("#btn_session_inc")
                }.expectation {
                    select("#txt_session_count").textIs("session=1")
                }
            }
        }
    }

    @Test("appSwitcher の後の ifCanSelect は、黙って偽にせず赤")
    func S0040() {
        scenario {
            scene(1, "スイッチャーの間に条件で分ける") {
                condition {
                    launchApp()
                    tap("#nav_lifecycle", scroll: .down)
                }.action {
                    appSwitcher()
                    ifCanSelect("#btn_session_inc") {
                        tap("#btn_session_inc")
                    }
                }.expectation {
                    select("#txt_session_count").textIs("session=1")
                }
            }
        }
    }

    @Test("スイッチャーから tapAppIcon で戻った後は断らない")
    func S0050() {
        scenario {
            scene(1, "スイッチャーから戻って押す") {
                condition {
                    launchApp()
                    tap("#nav_lifecycle", scroll: .down)
                }.action {
                    appSwitcher()
                    tapAppIcon()
                    tap("#btn_session_inc")
                }.expectation {
                    select("#txt_session_count").textIs("session=1")
                }
            }
        }
    }

    @Test("スイッチャーから home した後に押すと、背面と言って赤")
    func S0060() {
        scenario {
            scene(1, "スイッチャーから home して押す") {
                condition {
                    launchApp()
                    tap("#nav_lifecycle", scroll: .down)
                }.action {
                    appSwitcher()
                    home()
                    tap("#btn_session_inc")
                }.expectation {
                    select("#txt_session_count").textIs("session=1")
                }
            }
        }
    }
}
