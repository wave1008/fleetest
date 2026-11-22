// 34_表示条件のバリアント.swift
// fleetest 機能: 実行プロファイルの `variants`(DR-223〜225)。`ios-variants / android-variants` が宣言する `default` と `dark` のそれぞれで走り、
// `currentVariant` に応じた外観がアプリへ届いていることを表示条件画面の `#txt_appearance` で確かめる。
// バリアントの無いプロファイルでは `currentVariant` が nil なので light を確かめる(既存のプロファイルでも通る)。
// 文字サイズの生の値は OS ごとに違い SUT に対応表が無いので、ここでは外観だけを期待値にする(`dark` は `extraLarge` も指定する)。
import FTDSL

@TestClass
class 表示条件のバリアント {

    @Test("バリアントの外観がアプリに届く(dark なら dark・それ以外は light)")
    func S0010() {
        let expected = currentVariant == "dark" ? "dark" : "light"
        scenario {
            scene(1, "表示条件画面を開くとバリアントの外観") {
                condition {
                    launchApp()
                    tap("#nav_lifecycle", scroll: .down)
                    tap("#btn_open_display", scroll: .down)
                }.expectation {
                    select("#txt_appearance", waitSeconds: 10).textIs(expected, waitSeconds: 10)
                    exist("#txt_text_size")
                }
            }
        }
    }
}
