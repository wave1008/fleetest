package com.ftester.e2e.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import com.ftester.e2e.Tags
import com.ftester.e2e.ui.ScreenColumn
import com.ftester.e2e.util.rawTextSize

// 契約: docs/ui-contract.md「表示条件画面」。アプリが受け取った外観と文字サイズの生の値を出すだけ(アプリの配色は追従させない)。
// **2つの表示は白地に黒で固定する**: テーマの既定色のままだと、iOS でダークにしたとき背景だけ黒になり文字も黒のまま =
// テキストの可視性検証が「描かれていない」と正しく赤にした(2026-11-22)
@Composable
fun DisplayScreen() {
    ScreenColumn(scrollable = true) {
        ReadableText(Tags.TXT_APPEARANCE, if (isSystemInDarkTheme()) "dark" else "light")
        ReadableText(Tags.TXT_TEXT_SIZE, rawTextSize())
    }
}

@Composable
private fun ReadableText(tag: String, text: String) {
    Text(text = text, color = Color.Black, modifier = Modifier.background(Color.White).testTag(tag))
}
