// 99_キーボードの下の文中リンク.swift
// **陽性対照**(既定スイートには載せない): キーボードの下に沈んだ文字を `tap(要素, linkText:)` で叩くと、
// 撃たずに断ることを DSL で端から端まで確かめる。回すのは Scripts/e2e-negative.sh(期待値は Scripts/negative-controls.json)。
// witness は E2EAppIOS のキーボードの覆い画面の `#kb_footer`(キーボードが出ている間だけ window の下端から 60pt 上 = 必ずキーボードの内側)。
// **S0010 は落ちるのが正常**: 決めた点がキーボードの枠の中なので撃つ前に断る(`linkTextPointCoverRefusal`)。
// **緑になったら退行**(キーボードのキーを押していて上の欄に文字が入る)。
// MCP の replay では外側のキーボードの門が先に断って、この門まで届かない。
// CMP・Flutter 等の画面はキーボードぶん中身を縮めるので、文字がキーボードの下に沈む形をこの SUT でしか作れない
import FTDSL

@TestClass(platform: "ios")
class キーボードの下の文中リンク {

    @Test("キーボードの下に沈んだ文字を linkText で叩くと断る(落ちるのが正常)")
    func S0010() {
        scenario {
            scene(1, "上の欄で焦点を取ってキーボードを立てる") {
                condition {
                    launchApp()
                    tap("#nav_keyboard_cover", scroll: .down)
                }.action {
                    tap("#field_above_keyboard")
                }.expectation {
                    exist("#kb_footer", waitSeconds: 5)
                }
            }
            scene(2, "沈んだ文字を linkText で叩く → 断られる") {
                action {
                    tap("#kb_footer", linkText: "キーボードの下の文")
                }
            }
        }
    }
}
