// 90_中身の無い葉をスコープにする.swift
// **陽性対照**(既定スイートには載せない): xcuitest モードで、中身を持たない葉を `>>` の容器にした tap が、隣の入れ物の中身を
// 「子孫」と数えて別の要素を押さないことを確かめる。回すのは Scripts/e2e-negative.sh(期待値は Scripts/negative-controls.json)。
// XCUITest ランナーは木に出さない Flutter のセマンティクスの容器(本当のクラス名 `SemanticsObjectContainer`)を見分けて keptDepth を送る。
// **S0010 は落ちるのが正常**(`#txt_nested_result` は葉 = 下に何も無い)。緑になったら退行(depth で数えて隣の一覧のカードを押している)。
// **S0020 は緑が正常**(本物の容器 `#list_nested` の `>>` が壊れていない)
import FTDSL

@TestClass(platform: "ios")
class 中身の無い葉をスコープにする {

    @Test("葉をスコープにした tap は断られる(落ちるのが正常)")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_nested", scroll: .down)
                }.action {
                    tap("#txt_nested_result >> #card_0_01", waitSeconds: 2)
                }
            }
        }
    }

    @Test("本物の容器の >> は押せる")
    func S0020() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_nested", scroll: .down)
                }.action {
                    tap("#list_nested >> #card_0_01")
                }.expectation {
                    select("#txt_nested_result").textIs("nested=card_0_01")
                }
            }
        }
    }
}
