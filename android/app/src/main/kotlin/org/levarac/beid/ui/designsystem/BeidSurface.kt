package org.levarac.beid.ui.designsystem

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import org.levarac.beid.ui.theme.BeidTheme

/**
 * The one sanctioned way to give a composable a physical surface —
 * `surfaceRaised` fill plus a hairline stroke. Ports iOS's
 * `View.beidSurface(cornerRadius:)` (`ios/Beid/DesignSystem.swift`), material-
 * fallback path only: Android has no Liquid Glass equivalent and no
 * "below OS 26" branch to speak of, so this is that fallback path alone,
 * always applied.
 */
fun Modifier.beidSurface(cornerRadius: Dp): Modifier = composed {
    val colors = BeidTheme.colors
    val shape = RoundedCornerShape(cornerRadius)
    this
        .background(color = colors.surfaceRaised, shape = shape)
        .border(width = 1.dp, color = colors.strokeHairline, shape = shape)
}
