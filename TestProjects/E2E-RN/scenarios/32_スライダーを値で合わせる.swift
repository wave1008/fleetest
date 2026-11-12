// 32_スライダーを値で合わせる.swift
// fleetest 機能: `setSliderValue`(スライダーを値で1回で合わせる。値は木の value に出る数)。
// 契約: `#slider_volume` は 0..100・25 刻み、`#txt_slider` = `volume=<n>`(E2EAppCMP/docs/ui-contract.md)。
import FTDSL

@TestClass
class スライダーを値で合わせられること {

    @Test("setSliderValue で刻み 25 のスライダーを 75 と 25 に合わせる")
    func S0010() {
        scenario {
            scene(1, "コントロール画面を初期値にする") {
                condition {
                    launchApp()
                }.action {
                    tap("#tab_controls")
                    tap("#btn_controls_reset", scroll: .down)
                    scrollToTop()
                }.expectation {
                    select("#txt_slider").textIs("volume=50")
                }
            }
            scene(2, "75 に上げる") {
                action {
                    setSliderValue("#slider_volume", 75)
                }.expectation {
                    select("#txt_slider").textIs("volume=75")
                }
            }
            scene(3, "25 に下げる") {
                action {
                    setSliderValue("#slider_volume", 25)
                }.expectation {
                    select("#txt_slider").textIs("volume=25")
                }
            }
        }
    }
}
