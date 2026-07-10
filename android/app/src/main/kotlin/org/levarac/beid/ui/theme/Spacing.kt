package org.levarac.beid.ui.theme

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** 4dp base spacing scale, ported from DESIGN.md §7 / iOS `DS.Space`. */
object BeidSpacing {
    val xs: Dp = 4.dp
    val s: Dp = 8.dp
    val m: Dp = 16.dp
    val l: Dp = 24.dp
    val xl: Dp = 32.dp
    val xxl: Dp = 48.dp

    /** Default horizontal page margin for full-width content and CTAs. */
    val pageMargin: Dp = 32.dp
}

/** Corner radii, ported from DESIGN.md §8 / iOS `DS.Radius`. */
object BeidRadius {
    val control: Dp = 12.dp
    val card: Dp = 16.dp
    val seal: Dp = 28.dp
    val pill: Dp = 999.dp
}
