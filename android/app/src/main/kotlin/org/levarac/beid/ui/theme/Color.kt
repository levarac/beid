package org.levarac.beid.ui.theme

import androidx.compose.ui.graphics.Color

/**
 * Tier 1: the 13 Flat 2b Library colors, one per iOS
 * `ios/Beid/DesignSystem/Colors.xcassets` colorset (DESIGN.md §4, §5).
 * Single appearance: the Library has one value per variable and no dark
 * variant, so neither does this palette.
 *
 * Never referenced directly by composables — screens read the role tokens in
 * [BeidColorScheme] through `BeidTheme.colors`.
 */
internal object BeidPalette {
    /** Library `ink`. */
    val Ink = Color(0xFF0B0B0F)

    /** Library `bg`. */
    val Bg = Color(0xFFFFFFFF)

    /** Library `sub`. */
    val Sub = Color(0xFF6E6E78)

    /** Library `line`. */
    val Line = Color(0xFFECECF1)

    /** Library `line-dashed`. */
    val LineDashed = Color(0xFFC9C9CF)

    /** Library `tile`. */
    val Tile = Color(0xFFF2F2F4)

    /** Library `chart-muted`. */
    val ChartMuted = Color(0xFFD9D9DE)

    /** Library `on-ink/sub`. */
    val OnInkSub = Color(0xFF8E8E96)

    /** Library `on-ink/line`. */
    val OnInkLine = Color(0xFF2A2A31)

    /** Library `on-ink/idle`. */
    val OnInkIdle = Color(0xFF5C5C66)

    /** Library `semantic/red`. */
    val SemanticRed = Color(0xFFFF453A)

    /** Library `semantic/amber`. */
    val SemanticAmber = Color(0xFFFF9F0A)

    /** Library `semantic/green`. */
    val SemanticGreen = Color(0xFF30D158)
}

/**
 * Tier 2: role tokens — the Compose equivalent of iOS's `DS.Color.*`
 * (`ios/Beid/DesignSystem/Tokens.swift`), with the same names, each mapped
 * onto the same Library primitive as iOS. Several roles may share a
 * primitive. Roles and their allowed uses are in DESIGN.md §5.
 *
 * Semantic colors ([statusOn], [statusPending], [statusOff]) are indicators:
 * on the page ground they color a dot paired with a text label, never the
 * text itself (DESIGN.md §5, §13).
 */
data class BeidColorScheme(
    /** Page ground of every screen. Library `bg`. */
    val surfaceCanvas: Color,
    /** Primary text and marks (icons, neutral dots) on the page ground. Library `ink`. */
    val textPrimary: Color,
    /** Secondary text and section labels on the page ground. Library `sub`. */
    val textSecondary: Color,
    /** Row and list dividers on the page ground. Library `line`. */
    val strokeHairline: Color,
    /** Dashed frame of the empty block (`Block/Empty`). Library `line-dashed`. */
    val strokeEmptyState: Color,
    /** Gray tiles and the timeline track. Library `tile`. */
    val surfaceTile: Color,
    /** "Detected" bars in charts. Library `chart-muted`. */
    val chartDetected: Color,
    /** Secondary text on an ink ground. Library `on-ink/sub`. */
    val textSecondaryOnInk: Color,
    /** Dividers, graph rings and future-window bars on an ink ground. Library `on-ink/line`. */
    val strokeHairlineOnInk: Color,
    /** Detected-only (idle) graph nodes on an ink ground. Library `on-ink/idle`. */
    val graphNodeIdle: Color,
    /** `Button/Primary` Tone=Primary fill; also the screen tint. Library `ink`. */
    val actionPrimary: Color,
    /** Label on an [actionPrimary] fill. Library `bg`. */
    val labelOnActionPrimary: Color,
    /** `Button/Primary` Tone=Inverse fill, for black screens and the black sheet. Library `bg`. */
    val actionInverse: Color,
    /** Label on an [actionInverse] fill. Library `ink`. */
    val labelOnActionInverse: Color,
    /** Active / on. A dot on the page ground; text only on an ink ground. Library `semantic/green`. */
    val statusOn: Color,
    /** Verifying / pending. Same restriction as [statusOn]. Library `semantic/amber`. */
    val statusPending: Color,
    /** Destructive / off. Same restriction as [statusOn]. Library `semantic/red`. */
    val statusOff: Color,
)

/** The one Flat 2b color scheme. There is no dark variant (single appearance). */
internal val BeidColors = BeidColorScheme(
    surfaceCanvas = BeidPalette.Bg,
    textPrimary = BeidPalette.Ink,
    textSecondary = BeidPalette.Sub,
    strokeHairline = BeidPalette.Line,
    strokeEmptyState = BeidPalette.LineDashed,
    surfaceTile = BeidPalette.Tile,
    chartDetected = BeidPalette.ChartMuted,
    textSecondaryOnInk = BeidPalette.OnInkSub,
    strokeHairlineOnInk = BeidPalette.OnInkLine,
    graphNodeIdle = BeidPalette.OnInkIdle,
    actionPrimary = BeidPalette.Ink,
    labelOnActionPrimary = BeidPalette.Bg,
    actionInverse = BeidPalette.Bg,
    labelOnActionInverse = BeidPalette.Ink,
    statusOn = BeidPalette.SemanticGreen,
    statusPending = BeidPalette.SemanticAmber,
    statusOff = BeidPalette.SemanticRed,
)
