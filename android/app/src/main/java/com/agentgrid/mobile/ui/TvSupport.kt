package com.agentgrid.mobile.ui

import android.content.Context
import android.content.pm.PackageManager
import androidx.compose.foundation.border
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.unit.dp

/** 电视和机顶盒通常没有摄像头，此时不能把扫码当作唯一的配对方式。 */
internal fun hasCamera(context: Context): Boolean =
    context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)

/**
 * 遥控器方向键移动焦点时给出可见的焦点框。必须放在 `clickable` 之前，
 * 这样 `onFocusChanged` 才能观察到后面可聚焦节点的状态。
 */
@Composable
internal fun Modifier.focusHighlight(): Modifier {
    var focused by remember { mutableStateOf(false) }
    return this
        .onFocusChanged { focused = it.isFocused }
        .then(
            if (focused) Modifier.border(2.dp, AgentGridColors.Amber) else Modifier,
        )
}
