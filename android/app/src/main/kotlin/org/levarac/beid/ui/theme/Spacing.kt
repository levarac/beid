package org.levarac.beid.ui.theme

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** 4dp base spacing scale, equal to iOS `DS.Space` (DESIGN.md §7). */
object BeidSpacing {
    val xs: Dp = 4.dp
    val s: Dp = 8.dp
    val m: Dp = 16.dp
    val l: Dp = 24.dp
    val xl: Dp = 32.dp
    val xxl: Dp = 48.dp

    /** Default horizontal page margin for full-width content and CTAs (Flat 2b). */
    val pageMargin: Dp = 24.dp

    /** Vertical padding of the empty block (`Block/Empty`, DESIGN.md §8). */
    val emptyBlockVertical: Dp = 40.dp
}

/**
 * Corner radii, equal to iOS `DS.Radius` (DESIGN.md §8). `Button/Primary`
 * is a capsule, expressed with [pill].
 */
object BeidRadius {
    /** Small controls and inline chips. */
    val control: Dp = 12.dp

    /** Standard cards. */
    val card: Dp = 16.dp

    /** Proof seal artwork and ceremony surfaces. */
    val seal: Dp = 28.dp

    /** Fully rounded pills and capsule buttons. */
    val pill: Dp = 999.dp

    /** Frame of the empty block (`Block/Empty`). */
    val emptyBlock: Dp = 16.dp

    /** The now-sensing ink card (DESIGN.md §8). */
    val nowCard: Dp = 20.dp

    /**
     * Icon-roundel corner radius (`BeidGlyph`). Android-only: no iOS `DS.Radius`
     * counterpart (ported from the pre-#628 iOS `BeidDesign.Radius.glyph`).
     */
    val glyph: Dp = 24.dp
}

/**
 * Fixed component sizes. [statusDot] and [stepBadge] equal iOS `DS.Size`;
 * [glyph] and [bulletIcon] are Android-only.
 */
object BeidSize {
    /** `BeidGlyph`'s default icon-roundel diameter. Android-only. */
    val glyph: Dp = 72.dp

    /** `BeidStatusPill`'s indicator dot diameter (iOS `DS.Size.statusDot`). */
    val statusDot: Dp = 8.dp

    /** `BeidBulletRow`'s icon-roundel diameter. Android-only. */
    val bulletIcon: Dp = 32.dp

    /** `BeidNumberedStepList`'s filled index-badge diameter (iOS `DS.Size.stepBadge`). */
    val stepBadge: Dp = 28.dp
}
