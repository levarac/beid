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
 * Fixed component sizes. Every entry except [glyph] and [bulletIcon]
 * (Android-only) equals the iOS `DS.Size` token of the same name.
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

    /** The 1 pt rule: hairlines, the neutral Sigil ring, and the radar's rings and edges (iOS `DS.Size.hairline`). */
    val hairline: Dp = 1.dp

    /** Proof row minimum height (iOS `DS.Size.proofRowMinHeight`). */
    val proofRowMinHeight: Dp = 72.dp

    /** Flat 2b 06 Sensing — Sealed Sigil slot, node 184:65 (iOS `DS.Size.sensingSealedSigil`). */
    val sensingSealedSigil: Dp = 300.dp

    /** Flat 2b 09 Proof Detail artwork slot, node 204:36 (iOS `DS.Size.proofDetailSigil`). */
    val proofDetailSigil: Dp = 200.dp

    /**
     * Saved-record artwork in the two-column Records grid (iOS
     * `DS.Size.recordsGridSigil`, drafts feat/ios-v2-now-records and
     * integration/ios-1.1.1; not on iOS main yet).
     */
    val recordsGridSigil: Dp = 104.dp

    /** Flat 2b 05 Sensing radar field (iOS `DS.Size.radarField`). */
    val radarField: Dp = 362.dp

    /** The radar's three ring-path diameters at [radarField] (iOS `DS.Size.radarRing*`). */
    val radarRingInner: Dp = 133.22.dp
    val radarRingMiddle: Dp = 233.12.dp
    val radarRingOuter: Dp = 333.04.dp

    /** White centre disc of the radar's "me" core (iOS `DS.Size.radarCore`). */
    val radarCore: Dp = 38.dp

    /** Ink ring separating the core from the field (iOS `DS.Size.radarCoreSeparation`). */
    val radarCoreSeparation: Dp = 48.dp

    /** Ink dot at the core's centre (iOS `DS.Size.radarCenterDot`). */
    val radarCenterDot: Dp = 8.dp

    /** Detected-only peer node diameter and its outline width (iOS `DS.Size.radarDetectedNode*`). */
    val radarDetectedNode: Dp = 8.dp
    val radarDetectedNodeStroke: Dp = 1.5.dp
}
