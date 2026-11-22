package com.ftester.e2e.util

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalDensity
import platform.UIKit.UIApplication

// 文字サイズが変わると Compose が Density.fontScale を更新して再構成されるので、それを鍵に OS の生の値を読み直す。
@Composable
actual fun rawTextSize(): String {
    val fontScale = LocalDensity.current.fontScale
    return remember(fontScale) { UIApplication.sharedApplication.preferredContentSizeCategory ?: "unknown" }
}
