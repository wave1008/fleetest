package com.ftester.e2e.util

import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalConfiguration

@Composable
actual fun rawTextSize(): String = "%.2f".format(LocalConfiguration.current.fontScale)
