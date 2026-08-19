package org.levarac.beid.ui.theme

import androidx.compose.ui.graphics.Color

/**
 * Primitive hex anchors ported from DESIGN.md §5 "Color" / iOS
 * `Colors.xcassets`. Never referenced directly by composables — see
 * [BeidColorScheme] for the semantic (`DS`-equivalent) tokens screens use.
 */
internal object BeidPalette {
    val SurfaceCanvasLight = Color(0xFFF7F4EE)
    val SurfaceCanvasDark = Color(0xFF111315)

    val SurfaceRaisedLight = Color(0xFFFFFFFF)
    val SurfaceRaisedDark = Color(0xFF1B1E20)

    val TextPrimaryLight = Color(0xFF1A1C1E)
    val TextPrimaryDark = Color(0xFFECEDEE)

    val TextSecondaryLight = Color(0xFF5C6165)
    val TextSecondaryDark = Color(0xFF9BA1A6)

    val ActionPrimaryLight = Color(0xFF2A2E33)
    val ActionPrimaryDark = Color(0xFFE8EAEC)

    val SignalActiveLight = Color(0xFF18C7A7)
    val SignalActiveDark = Color(0xFF62E8D0)

    val SignalWarningLight = Color(0xFFC7841A)
    val SignalWarningDark = Color(0xFFE8B562)

    val ProofSealLight = Color(0xFF6E5AEF)
    val ProofSealDark = Color(0xFF9D8CFF)

    val LabelOnWarningLight = Color(0xFF1A1C1E)
    val LabelOnWarningDark = Color(0xFF111315)

    val LabelOnSealLight = Color(0xFFFFFFFF)
    val LabelOnSealDark = Color(0xFF111315)

    val StrokeHairlineLight = Color(0xFFE3DFD6)
    val StrokeHairlineDark = Color(0xFF2A2E31)

    /** DESIGN.md §5 "Binary on/off status, 'on'" — e.g. the Account screen's Bluetooth-active badge. */
    val StatusOnLight = Color(0xFF1E7E34)
    val StatusOnDark = Color(0xFF30D158)

    /** DESIGN.md §5 "Binary on/off status, 'off'" — e.g. the Account screen's Bluetooth-off badge. */
    val StatusOffLight = Color(0xFF6B7075)
    val StatusOffDark = Color(0xFF83898F)
}

/**
 * Semantic color tokens — the Compose equivalent of iOS's `DS.Color.*`
 * namespace (DESIGN.md §4 "Token Architecture"). Screens read colors through
 * [org.levarac.beid.ui.theme.BeidTheme]'s `LocalBeidColors`, never through
 * [BeidPalette] directly.
 */
data class BeidColorScheme(
    val surfaceCanvas: Color,
    val surfaceRaised: Color,
    val textPrimary: Color,
    val textSecondary: Color,
    val actionPrimary: Color,
    val signalActive: Color,
    val signalWarning: Color,
    val proofSeal: Color,
    val labelOnWarning: Color,
    val labelOnSeal: Color,
    val strokeHairline: Color,
    val statusOn: Color,
    val statusOff: Color,
)

internal val LightBeidColors = BeidColorScheme(
    surfaceCanvas = BeidPalette.SurfaceCanvasLight,
    surfaceRaised = BeidPalette.SurfaceRaisedLight,
    textPrimary = BeidPalette.TextPrimaryLight,
    textSecondary = BeidPalette.TextSecondaryLight,
    actionPrimary = BeidPalette.ActionPrimaryLight,
    signalActive = BeidPalette.SignalActiveLight,
    signalWarning = BeidPalette.SignalWarningLight,
    proofSeal = BeidPalette.ProofSealLight,
    labelOnWarning = BeidPalette.LabelOnWarningLight,
    labelOnSeal = BeidPalette.LabelOnSealLight,
    strokeHairline = BeidPalette.StrokeHairlineLight,
    statusOn = BeidPalette.StatusOnLight,
    statusOff = BeidPalette.StatusOffLight,
)

internal val DarkBeidColors = BeidColorScheme(
    surfaceCanvas = BeidPalette.SurfaceCanvasDark,
    surfaceRaised = BeidPalette.SurfaceRaisedDark,
    textPrimary = BeidPalette.TextPrimaryDark,
    textSecondary = BeidPalette.TextSecondaryDark,
    actionPrimary = BeidPalette.ActionPrimaryDark,
    signalActive = BeidPalette.SignalActiveDark,
    signalWarning = BeidPalette.SignalWarningDark,
    proofSeal = BeidPalette.ProofSealDark,
    labelOnWarning = BeidPalette.LabelOnWarningDark,
    labelOnSeal = BeidPalette.LabelOnSealDark,
    strokeHairline = BeidPalette.StrokeHairlineDark,
    statusOn = BeidPalette.StatusOnDark,
    statusOff = BeidPalette.StatusOffDark,
)
