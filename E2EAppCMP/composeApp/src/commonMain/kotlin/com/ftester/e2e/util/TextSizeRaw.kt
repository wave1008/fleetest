package com.ftester.e2e.util

import androidx.compose.runtime.Composable

/** OS の生の文字サイズ。Android = Configuration.fontScale(小数2桁)/ iOS = UIContentSizeCategory の rawValue。 */
@Composable
expect fun rawTextSize(): String
