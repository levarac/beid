package org.levarac.beid.ui.theme

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf

/**
 * Exposes [BeidColorScheme] (the `DS.Color.*` equivalent) to composables.
 * Prefer `BeidTheme.colors` over reading this local directly.
 */
private val LocalBeidColors = staticCompositionLocalOf { BeidColors }

/** Screen-facing accessor mirroring iOS's `DS` namespace usage pattern. */
object BeidTheme {
    val colors: BeidColorScheme
        @Composable get() = LocalBeidColors.current
}

/**
 * Material3 slots that Material components read, filled from the role tokens.
 * Only slots with a clear iOS `DS.Color` counterpart are set; screens should
 * still prefer `BeidTheme.colors.*` over `MaterialTheme.colorScheme.*` so the
 * mapping stays in one place.
 */
internal fun beidMaterialColorScheme(colors: BeidColorScheme): ColorScheme = lightColorScheme(
    background = colors.surfaceCanvas,
    onBackground = colors.textPrimary,
    surface = colors.surfaceCanvas,
    onSurface = colors.textPrimary,
    onSurfaceVariant = colors.textSecondary,
    primary = colors.actionPrimary,
    onPrimary = colors.labelOnActionPrimary,
    outline = colors.strokeHairline,
    outlineVariant = colors.strokeHairline,
)

/**
 * Root theme composable — the Compose equivalent of applying `DS` tokens at
 * the app root on iOS. Wrap the app's content in this once, in
 * `MainActivity`.
 *
 * Single appearance (Flat 2b, iOS #632): the app draws the same colors
 * whatever the system dark-mode setting is, so there is no dark scheme.
 */
@Composable
fun BeidAppTheme(content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalBeidColors provides BeidColors) {
        MaterialTheme(
            colorScheme = beidMaterialColorScheme(BeidColors),
            typography = BeidTypography,
            content = content,
        )
    }
}
